import Foundation
import XCTest
import MotionProbeCore

final class CaptureStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testCSVIncludesRawSamplesAndTimedHapticRequests() throws {
        let store = try CaptureStore(url: directory.appendingPathComponent("motion.sqlite"))
        let id = try store.begin(CaptureSetup(kind: .haptics, posture: .lowered, device: "Watch"), uptime: 40)
        let zero = Vector3(x: 0, y: 0, z: 0)
        try store.append([MotionSample(uptime: 42.25, acceleration: zero, rotation: zero, gravity: zero, dimmed: true)], to: id)
        try store.recordEvent("haptic_requested", detail: "dimmed, \"inactive\"", uptime: 42.25, in: id)
        try store.finish(id, status: "completed", uptime: 70)

        let event = try XCTUnwrap(store.events(for: id).first)
        XCTAssertEqual(event.uptime, 42.25)
        XCTAssertEqual(event.name, "haptic_requested")
        XCTAssertEqual(event.detail, "dimmed, \"inactive\"")
        let capture = try XCTUnwrap(store.latest())
        let export = directory.appendingPathComponent("capture.csv")
        try store.exportCSV(capture, to: export)
        let csv = try String(contentsOf: export, encoding: .utf8)
        XCTAssertTrue(csv.contains("sample,\(id),haptics,lowered,42.25,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,1,,"))
        XCTAssertTrue(csv.contains("haptic_requested,\"dimmed, \"\"inactive\"\"\""))
        XCTAssertTrue(csv.contains("completed"))
    }

    func testStoppedRecordingRejectsLateSensorSamples() throws {
        let store = try CaptureStore(url: directory.appendingPathComponent("motion.sqlite"))
        let id = try store.begin(CaptureSetup(kind: .still, posture: .lowered, device: "Watch"), uptime: 10)
        try store.finish(id, status: "cancelled", uptime: 11)
        let zero = Vector3(x: 0, y: 0, z: 0)
        let lateSample = MotionSample(uptime: 12, acceleration: zero, rotation: zero, gravity: zero, dimmed: true)
        XCTAssertThrowsError(try store.append([lateSample], to: id))
        XCTAssertEqual(try store.summary(for: id).sampleCount, 0)
    }

    func testSummaryShowsSamplingGapsAndDimmedScreenSamples() throws {
        let store = try CaptureStore(url: directory.appendingPathComponent("motion.sqlite"))
        let id = try store.begin(CaptureSetup(kind: .normalMovement, posture: .lowered, device: "Watch"), uptime: 100)
        let zero = Vector3(x: 0, y: 0, z: 0)
        let samples = [100.00, 100.01, 100.02, 100.52].enumerated().map { index, uptime in
            MotionSample(uptime: uptime, acceleration: zero, rotation: zero, gravity: zero, dimmed: index >= 2)
        }
        try store.append(samples, to: id)
        try store.finish(id, status: "completed", uptime: 130)

        let summary = try store.summary(for: id)
        XCTAssertEqual(summary.sampleCount, 4)
        XCTAssertEqual(summary.dimmedSampleCount, 2)
        XCTAssertEqual(summary.sampleSpan, 0.52, accuracy: 0.0001)
        XCTAssertEqual(summary.largestGap, 0.5, accuracy: 0.0001)
        XCTAssertEqual(summary.observedHz, 3 / 0.52, accuracy: 0.0001)
    }

    func testRecordingSurvivesClosingAndReopeningTheDatabase() throws {
        let database = directory.appendingPathComponent("motion.sqlite")
        let sample = MotionSample(
            uptime: 101,
            acceleration: Vector3(x: 0.1, y: -0.2, z: 0.3),
            rotation: Vector3(x: 1, y: 2, z: 3),
            gravity: Vector3(x: 0, y: -1, z: 0),
            dimmed: true
        )
        let captureID: String
        do {
            let store = try CaptureStore(url: database)
            captureID = try store.begin(CaptureSetup(kind: .doublePinch, posture: .lowered, device: "Test Watch"), uptime: 100)
            try store.append([sample], to: captureID)
            try store.finish(captureID, status: "completed", uptime: 102)
        }
        let reopened = try CaptureStore(url: database)
        let capture = try XCTUnwrap(reopened.latest())
        XCTAssertEqual(capture.id, captureID)
        XCTAssertEqual(capture.kind, .doublePinch)
        XCTAssertEqual(capture.posture, .lowered)
        XCTAssertEqual(capture.status, "completed")
        XCTAssertEqual(try reopened.samples(for: captureID), [sample])
    }
}
