import AVFoundation
import OSLog
import SwiftUI
import WatchKit

@MainActor
final class TasbeehModel: NSObject, ObservableObject {
    @Published private(set) var counter: TasbeehCounter?
    @Published private(set) var status = ""

    private let logger = Logger(subsystem: "com.example.SobhaMotionProbe", category: "Tasbeeh")
    private var store: TasbeehStore?
    private var runtime: WKExtendedRuntimeSession?
    private var player: AVAudioPlayer?

    override init() {
        super.init()
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
            let store = try TasbeehStore(url: documents.appendingPathComponent("tasbeeh.sqlite"))
            self.store = store
            if let snapshot = try store.load() {
                counter = TasbeehCounter(snapshot: snapshot)
                startRuntime()
            }
        } catch {
            status = "Storage error: \(error.localizedDescription)"
        }
    }

    func start(target: Int) {
        counter = TasbeehCounter(target: target)
        persist()
        startRuntime()
        if let statement = counter?.statement { announce(statement) }
    }

    func tap() {
        guard var current = counter else { return }
        let event = current.increment()
        counter = current
        persist()
        WKInterfaceDevice.current().play(.click)
        if case .roundCompleted(_, let next) = event {
            WKInterfaceDevice.current().play(.notification)
            announce(next)
        }
    }

    func reset() {
        counter = nil
        player?.stop()
        player = nil
        do { try store?.clear() }
        catch { status = "Storage error: \(error.localizedDescription)" }
        releaseRuntime()
    }

    private func persist() {
        guard let counter else { return }
        do { try store?.save(counter.snapshot) }
        catch { status = "Storage error: \(error.localizedDescription)" }
    }

    private func announce(_ statement: TasbeehStatement) {
        guard let url = Bundle.main.url(forResource: statement.audioFileName, withExtension: "m4a") else {
            logger.error("Missing audio file \(statement.audioFileName, privacy: .public)")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            self.player = player
            player.play()
        } catch {
            logger.error("Audio playback failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startRuntime() {
        if let runtime, runtime.state == .running { return }
        let session = WKExtendedRuntimeSession()
        runtime = session
        session.delegate = self
        session.start()
    }

    private func releaseRuntime() {
        let session = runtime
        runtime = nil
        session?.delegate = nil
        if let session, session.state != .invalid { session.invalidate() }
    }
}

extension TasbeehModel: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSessionWillExpire(_ session: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSession(_ session: WKExtendedRuntimeSession,
                                            didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                            error: Error?) {
        Task { @MainActor in
            guard runtime === session else { return }
            runtime = nil
            // Restart only after natural expiry. A suppressed or resigned session is left off.
            if reason == .expired, counter != nil { startRuntime() }
        }
    }
}
