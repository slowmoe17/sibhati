import CoreMotion
import Darwin
import OSLog
import SwiftUI
import WatchKit

@MainActor
final class ProbeRecorder: NSObject, ObservableObject {
    @Published var kind: CaptureKind = .doublePinch
    @Published var posture: WristPosture = .lowered
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Choose a test"
    @Published private(set) var secondsRemaining = 0
    @Published private(set) var sampleCount = 0
    @Published private(set) var latest: Capture?
    @Published private(set) var summary: CaptureSummary?
    @Published private(set) var exportURL: URL?
    @Published private(set) var hapticRequests = 0
    @Published private(set) var canRecord = false

    private let motion = CMMotionManager()
    private let logger = Logger(subsystem: "com.example.SobhaMotionProbe", category: "Capture")
    private var store: CaptureStore?
    private var directory: URL?
    private var runtime: WKExtendedRuntimeSession?
    private var timer: Timer?
    private var captureID: String?
    private var buffer: [MotionSample] = []
    private var receivedSamples = 0
    private var windowStart = 0.0
    private var windowEnd = 0.0
    private var nextPulse = 5.0
    private var dimmed = false
    private var sceneState = "unknown"
    private let duration = 30.0
    private let requestedHz = 100.0

    override init() {
        super.init()
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
            let directory = documents.appendingPathComponent("MotionProbe", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.directory = directory
            store = try CaptureStore(url: directory.appendingPathComponent("motion.sqlite"))
            canRecord = motion.isDeviceMotionAvailable
            try loadResult()
            if !canRecord { status = "Motion sensors are unavailable" }
        } catch {
            status = "Storage error: \(error.localizedDescription)"
        }
    }

    func start() {
        guard !isRunning, canRecord, store != nil else { return }
        guard WKApplication.shared().applicationState == .active else {
            status = "Wake the Watch before starting"
            return
        }
        isRunning = true
        status = "Starting session"
        sampleCount = 0
        hapticRequests = 0
        exportURL = nil
        latest = nil
        summary = nil
        receivedSamples = 0
        buffer.removeAll(keepingCapacity: true)
        nextPulse = 5
        let session = WKExtendedRuntimeSession()
        runtime = session
        session.delegate = self
        session.start()
    }

    func cancel() { stop(status: "cancelled") }

    func displayChanged(dimmed: Bool, scene: ScenePhase) {
        let state: String
        switch scene {
        case .active: state = "active"
        case .inactive: state = "inactive"
        case .background: state = "background"
        @unknown default: state = "unknown"
        }
        guard self.dimmed != dimmed || sceneState != state else { return }
        self.dimmed = dimmed
        sceneState = state
        guard captureID != nil else { return }
        do {
            try recordEvent("display_state", detail: "dimmed=\(dimmed);scene=\(state)")
        } catch { stop(status: "storage_error", error: error.localizedDescription) }
    }

    private func beginRecording(_ session: WKExtendedRuntimeSession) {
        guard runtime === session, isRunning, let store else { return }
        do {
            let now = ProcessInfo.processInfo.systemUptime
            windowStart = now + 5
            windowEnd = windowStart + duration
            let setup = CaptureSetup(kind: kind, posture: posture, device: deviceDescription(), requestedHz: requestedHz)
            let id = try store.begin(setup, uptime: now)
            captureID = id
            try recordEvent("recording_window", detail: "start=\(windowStart);end=\(windowEnd)")
            try recordEvent("display_state", detail: "dimmed=\(dimmed);scene=\(sceneState)")
            status = "Get ready"
            secondsRemaining = 5
            startUpdates(captureID: id)
        } catch { stop(status: "storage_error", error: error.localizedDescription) }
    }

    private func startUpdates(captureID: String) {
        motion.deviceMotionUpdateInterval = 1 / requestedHz
        motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, error in
            self?.receive(sample, error: error, captureID: captureID)
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func receive(_ sample: CMDeviceMotion?, error: Error?, captureID: String) {
        // A queued callback from an old run must never enter a new recording.
        guard self.captureID == captureID else { return }
        if let error {
            stop(status: "sensor_error", error: error.localizedDescription)
            return
        }
        guard let sample, sample.timestamp >= windowStart, sample.timestamp < windowEnd else { return }
        buffer.append(motionSample(sample))
        receivedSamples += 1
        if buffer.count >= 100 {
            do { try flush() }
            catch { stop(status: "storage_error", error: error.localizedDescription) }
        }
    }

    private func motionSample(_ sample: CMDeviceMotion) -> MotionSample {
        MotionSample(
            uptime: sample.timestamp,
            acceleration: Vector3(x: sample.userAcceleration.x, y: sample.userAcceleration.y, z: sample.userAcceleration.z),
            rotation: Vector3(x: sample.rotationRate.x, y: sample.rotationRate.y, z: sample.rotationRate.z),
            gravity: Vector3(x: sample.gravity.x, y: sample.gravity.y, z: sample.gravity.z),
            dimmed: dimmed
        )
    }

    private func tick() {
        guard captureID != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        sampleCount = receivedSamples
        if now < windowStart {
            secondsRemaining = Int(ceil(windowStart - now))
            return
        }
        status = "Recording"
        secondsRemaining = Int(ceil(max(0, windowEnd - now)))
        if now >= windowEnd {
            stop(status: "completed")
            return
        }
        if kind == .haptics {
            do { try playScheduledPulses(elapsed: now - windowStart) }
            catch { stop(status: "storage_error", error: error.localizedDescription) }
        }
    }

    private func playScheduledPulses(elapsed: Double) throws {
        // Log missed timer slots instead of firing a burst after suspension.
        while nextPulse < duration, elapsed >= nextPulse {
            if elapsed - nextPulse < 1 {
                try recordEvent("haptic_requested", detail: "scheduled=\(nextPulse);dimmed=\(dimmed);scene=\(sceneState)")
                WKInterfaceDevice.current().play(.click)
                hapticRequests += 1
            } else {
                try recordEvent("haptic_skipped", detail: "scheduled=\(nextPulse);timer_late")
            }
            nextPulse += 5
        }
    }

    private func flush() throws {
        guard let captureID, let store, !buffer.isEmpty else { return }
        try store.append(buffer, to: captureID)
        buffer.removeAll(keepingCapacity: true)
    }

    private func recordEvent(_ name: String, detail: String) throws {
        guard let captureID, let store else { return }
        try store.recordEvent(name, detail: detail, uptime: ProcessInfo.processInfo.systemUptime, in: captureID)
    }

    private func stop(status outcome: String, error: String? = nil) {
        guard isRunning else { return }
        timer?.invalidate()
        timer = nil
        motion.stopDeviceMotionUpdates()
        var failure = error
        do { try closeCapture(outcome: outcome, error: error) }
        catch { failure = error.localizedDescription }
        captureID = nil
        isRunning = false
        secondsRemaining = 0
        releaseRuntime()
        do { try loadResult() }
        catch { failure = error.localizedDescription }
        status = failure.map { "Stopped: \($0)" } ?? (outcome == "completed" ? "Recording saved" : "Stopped: \(outcome)")
        logger.info("Capture ended: \(self.status, privacy: .public); samples=\(self.summary?.sampleCount ?? 0); span=\(self.summary?.sampleSpan ?? 0); maxGap=\(self.summary?.largestGap ?? 0)")
    }

    private func closeCapture(outcome: String, error: String?) throws {
        try flush()
        guard let captureID, let store else { return }
        try recordEvent("capture_stopped", detail: error ?? outcome)
        try store.finish(captureID, status: outcome, uptime: ProcessInfo.processInfo.systemUptime)
    }

    private func releaseRuntime() {
        // Clear the delegate before invalidating; an old callback cannot stop a new run.
        let session = runtime
        runtime = nil
        session?.delegate = nil
        if let session, session.state != .invalid { session.invalidate() }
    }

    private func loadResult() throws {
        guard let store, let capture = try store.latest(), let directory else { return }
        latest = capture
        summary = try store.summary(for: capture.id)
        sampleCount = summary?.sampleCount ?? 0
        hapticRequests = try store.events(for: capture.id).filter { $0.name == "haptic_requested" }.count
        let url = directory.appendingPathComponent("\(capture.id).csv")
        try store.exportCSV(capture, to: url)
        exportURL = url
        if capture.status == "recording" { status = "Prior recording was interrupted" }
    }

    private func hardwareIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "unknown Watch" }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &value, &size, nil, 0) == 0 else { return "unknown Watch" }
        return String(cString: value)
    }

    private func deviceDescription() -> String {
        let device = WKInterfaceDevice.current()
        return "\(hardwareIdentifier()), watchOS \(device.systemVersion), wrist=\(device.wristLocation.rawValue), crown=\(device.crownOrientation.rawValue)"
    }
}

extension ProbeRecorder: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) {
        Task { @MainActor in beginRecording(session) }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ session: WKExtendedRuntimeSession) {
        Task { @MainActor in
            guard runtime === session else { return }
            stop(status: "runtime_expiring")
        }
    }

    nonisolated func extendedRuntimeSession(_ session: WKExtendedRuntimeSession,
                                          didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                          error: Error?) {
        Task { @MainActor in
            guard runtime === session else { return }
            stop(status: "runtime_ended", error: error?.localizedDescription ?? "Runtime ended (\(reason.rawValue))")
        }
    }
}
