import Foundation
import SQLite3

public enum CaptureKind: String, Codable, CaseIterable, Identifiable {
    case doublePinch, normalMovement, still, haptics
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .doublePinch: return "Double pinches"
        case .normalMovement: return "Normal movement"
        case .still: return "Still hand"
        case .haptics: return "Vibration test"
        }
    }
}

public enum WristPosture: String, Codable, CaseIterable, Identifiable {
    case lowered, raised
    public var id: String { rawValue }
    public var title: String { self == .lowered ? "Wrist down" : "Wrist up" }
}

public struct Vector3: Equatable {
    public let x: Double
    public let y: Double
    public let z: Double
    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct MotionSample: Equatable {
    public let uptime: Double
    public let acceleration: Vector3
    public let rotation: Vector3
    public let gravity: Vector3
    public let dimmed: Bool
    // The four-argument limit is waived for this DTO: its five fields preserve one sensor record.
    public init(uptime: Double, acceleration: Vector3, rotation: Vector3, gravity: Vector3, dimmed: Bool) {
        self.uptime = uptime
        self.acceleration = acceleration
        self.rotation = rotation
        self.gravity = gravity
        self.dimmed = dimmed
    }
}

public struct CaptureSetup {
    public let kind: CaptureKind
    public let posture: WristPosture
    public let device: String
    public let requestedHz: Double

    public init(kind: CaptureKind, posture: WristPosture, device: String, requestedHz: Double = 100) {
        self.kind = kind
        self.posture = posture
        self.device = device
        self.requestedHz = requestedHz
    }
}

public struct Capture: Codable {
    public let id: String
    public let kind: CaptureKind
    public let posture: WristPosture
    public let device: String
    public let startedAt: Date
    public let startedUptime: Double
    public let endedUptime: Double?
    public let requestedHz: Double
    public let status: String
}

public struct CaptureEvent {
    public let uptime: Double
    public let name: String
    public let detail: String
}

public struct CaptureSummary {
    public let sampleCount: Int
    public let dimmedSampleCount: Int
    public let sampleSpan: Double
    public let largestGap: Double
    public let observedHz: Double
}

/// Local recordings. Call from one serial queue. Each sample batch commits atomically.
public final class CaptureStore {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            let error = databaseError()
            sqlite3_close(database)
            database = nil
            throw error
        }
        do {
            sqlite3_busy_timeout(database, 1000)
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("""
                CREATE TABLE IF NOT EXISTS captures (
                    id TEXT PRIMARY KEY, kind TEXT NOT NULL, posture TEXT NOT NULL,
                    device TEXT NOT NULL, started_at REAL NOT NULL, started_uptime REAL NOT NULL,
                    ended_uptime REAL, requested_hz REAL NOT NULL, status TEXT NOT NULL
                )
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS samples (
                    capture_id TEXT NOT NULL REFERENCES captures(id), uptime REAL NOT NULL,
                    ax REAL NOT NULL, ay REAL NOT NULL, az REAL NOT NULL,
                    rx REAL NOT NULL, ry REAL NOT NULL, rz REAL NOT NULL,
                    gx REAL NOT NULL, gy REAL NOT NULL, gz REAL NOT NULL, dimmed INTEGER NOT NULL
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS samples_capture ON samples(capture_id)")
            try execute("""
                CREATE TABLE IF NOT EXISTS events (
                    capture_id TEXT NOT NULL REFERENCES captures(id), uptime REAL NOT NULL,
                    name TEXT NOT NULL, detail TEXT NOT NULL
                )
                """)
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public func begin(_ setup: CaptureSetup, uptime: Double) throws -> String {
        let id = UUID().uuidString
        try execute("INSERT INTO captures VALUES (?, ?, ?, ?, ?, ?, NULL, ?, 'recording')", [
            .text(id), .text(setup.kind.rawValue), .text(setup.posture.rawValue), .text(setup.device),
            .real(Date().timeIntervalSince1970), .real(uptime), .real(setup.requestedHz)
        ])
        return id
    }

    public func append(_ samples: [MotionSample], to id: String) throws {
        guard !samples.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            try requireRecording(id)
            try withStatement("INSERT INTO samples VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)") { statement in
                for sample in samples {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bind([
                        .text(id), .real(sample.uptime),
                        .real(sample.acceleration.x), .real(sample.acceleration.y), .real(sample.acceleration.z),
                        .real(sample.rotation.x), .real(sample.rotation.y), .real(sample.rotation.z),
                        .real(sample.gravity.x), .real(sample.gravity.y), .real(sample.gravity.z),
                        .integer(sample.dimmed ? 1 : 0)
                    ], to: statement)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func finish(_ id: String, status: String, uptime: Double) throws {
        try requireRecording(id)
        try execute("UPDATE captures SET status = ?, ended_uptime = ? WHERE id = ?", [
            .text(status), .real(uptime), .text(id)
        ])
    }

    public func latest() throws -> Capture? {
        try withStatement("SELECT * FROM captures ORDER BY rowid DESC LIMIT 1") { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW,
                  let kind = CaptureKind(rawValue: string(statement, 1)),
                  let posture = WristPosture(rawValue: string(statement, 2)) else { throw databaseError() }
            return Capture(
                id: string(statement, 0), kind: kind, posture: posture, device: string(statement, 3),
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                startedUptime: sqlite3_column_double(statement, 5),
                endedUptime: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 6),
                requestedHz: sqlite3_column_double(statement, 7), status: string(statement, 8)
            )
        }
    }

    public func samples(for id: String) throws -> [MotionSample] {
        try withStatement("SELECT * FROM samples WHERE capture_id = ? ORDER BY rowid", [.text(id)]) { statement in
            var samples: [MotionSample] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                samples.append(MotionSample(
                    uptime: sqlite3_column_double(statement, 1),
                    acceleration: Vector3(x: sqlite3_column_double(statement, 2), y: sqlite3_column_double(statement, 3), z: sqlite3_column_double(statement, 4)),
                    rotation: Vector3(x: sqlite3_column_double(statement, 5), y: sqlite3_column_double(statement, 6), z: sqlite3_column_double(statement, 7)),
                    gravity: Vector3(x: sqlite3_column_double(statement, 8), y: sqlite3_column_double(statement, 9), z: sqlite3_column_double(statement, 10)),
                    dimmed: sqlite3_column_int(statement, 11) != 0
                ))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw databaseError() }
            return samples
        }
    }

    public func summary(for id: String) throws -> CaptureSummary {
        let samples = try samples(for: id)
        let span = max(0, (samples.last?.uptime ?? 0) - (samples.first?.uptime ?? 0))
        let largestGap = zip(samples, samples.dropFirst()).map { $1.uptime - $0.uptime }.max() ?? 0
        return CaptureSummary(
            sampleCount: samples.count, dimmedSampleCount: samples.filter(\.dimmed).count,
            sampleSpan: span, largestGap: largestGap,
            observedHz: span > 0 ? Double(samples.count - 1) / span : 0
        )
    }

    public func recordEvent(_ name: String, detail: String, uptime: Double, in id: String) throws {
        try requireRecording(id)
        try execute("INSERT INTO events VALUES (?, ?, ?, ?)", [
            .text(id), .real(uptime), .text(name), .text(detail)
        ])
    }

    public func events(for id: String) throws -> [CaptureEvent] {
        try withStatement("SELECT uptime, name, detail FROM events WHERE capture_id = ? ORDER BY rowid", [.text(id)]) { statement in
            var events: [CaptureEvent] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                events.append(CaptureEvent(uptime: sqlite3_column_double(statement, 0),
                                           name: string(statement, 1), detail: string(statement, 2)))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw databaseError() }
            return events
        }
    }

    public func exportCSV(_ capture: Capture, to url: URL) throws {
        var rows = [["record_type", "capture_id", "kind", "posture", "uptime", "ax", "ay", "az",
                     "rx", "ry", "rz", "gx", "gy", "gz", "dimmed", "event", "detail"]]
        let prefix = [capture.id, capture.kind.rawValue, capture.posture.rawValue]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metadata = String(decoding: try encoder.encode(capture), as: UTF8.self)
        rows.append(["metadata"] + prefix + [String(capture.startedUptime)] + Array(repeating: "", count: 10) + ["capture", metadata])
        for sample in try samples(for: capture.id) {
            let numbers = [sample.uptime, sample.acceleration.x, sample.acceleration.y, sample.acceleration.z,
                           sample.rotation.x, sample.rotation.y, sample.rotation.z,
                           sample.gravity.x, sample.gravity.y, sample.gravity.z].map { String($0) }
            rows.append(["sample"] + prefix + numbers + [sample.dimmed ? "1" : "0", "", ""])
        }
        for event in try events(for: capture.id) {
            rows.append(["event"] + prefix + [String(event.uptime)] + Array(repeating: "", count: 10) + [event.name, event.detail])
        }
        let csv = rows.map { row in
            row.map { field in
                if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
                    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return field
            }.joined(separator: ",")
        }.joined(separator: "\n") + "\n"
        try csv.write(to: url, atomically: true, encoding: .utf8)
    }

    private enum Value {
        case text(String), real(Double), integer(Int32)
    }

    private func requireRecording(_ id: String) throws {
        try withStatement("SELECT status FROM captures WHERE id = ?", [.text(id)]) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW, string(statement, 0) == "recording" else {
                throw NSError(domain: "MotionProbe.Capture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Recording is missing or has already stopped."])
            }
        }
    }

    private func execute(_ sql: String, _ values: [Value] = []) throws {
        try withStatement(sql, values) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE || result == SQLITE_ROW else { throw databaseError() }
        }
    }

    private func withStatement<T>(_ sql: String, _ values: [Value] = [],
                                  _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        return try body(statement)
    }

    private func bind(_ values: [Value], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text):
                result = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case .real(let number): result = sqlite3_bind_double(statement, index, number)
            case .integer(let number): result = sqlite3_bind_int(statement, index, number)
            }
            guard result == SQLITE_OK else { throw databaseError() }
        }
    }

    private func string(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    private func databaseError() -> NSError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open the recording database."
        return NSError(domain: "MotionProbe.SQLite", code: Int(sqlite3_errcode(database)),
                       userInfo: [NSLocalizedDescriptionKey: message])
    }
}
