import Foundation
import SQLite3

/// Persists the tasbeeh counter so a session survives relaunch. Call from one serial queue.
public final class TasbeehStore {
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
            try execute("PRAGMA journal_mode = WAL")
            try execute("""
                CREATE TABLE IF NOT EXISTS tasbeeh_state (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    target INTEGER NOT NULL, statement INTEGER NOT NULL,
                    count_in_round INTEGER NOT NULL, updated_at REAL NOT NULL
                )
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS tasbeeh_totals (
                    statement INTEGER PRIMARY KEY, total INTEGER NOT NULL
                )
                """)
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    /// Save the counter state and per-statement totals atomically.
    public func save(_ snapshot: TasbeehSnapshot) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("INSERT OR REPLACE INTO tasbeeh_state VALUES (1, ?, ?, ?, ?)", [
                .integer(Int32(snapshot.target)), .integer(Int32(snapshot.statementIndex)),
                .integer(Int32(snapshot.countInRound)), .real(Date().timeIntervalSince1970)
            ])
            try execute("DELETE FROM tasbeeh_totals")
            try withStatement("INSERT INTO tasbeeh_totals VALUES (?, ?)") { statement in
                for (index, total) in snapshot.totals {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bind([.integer(Int32(index)), .integer(Int32(total))], to: statement)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func load() throws -> TasbeehSnapshot? {
        guard let row = try stateRow() else { return nil }
        return TasbeehSnapshot(target: row.target, statementIndex: row.statement,
                               countInRound: row.countInRound, totals: try loadTotals())
    }

    public func clear() throws {
        try execute("DELETE FROM tasbeeh_state")
        try execute("DELETE FROM tasbeeh_totals")
    }

    private func stateRow() throws -> (target: Int, statement: Int, countInRound: Int)? {
        try withStatement("SELECT target, statement, count_in_round FROM tasbeeh_state WHERE id = 1") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return (Int(sqlite3_column_int(statement, 0)), Int(sqlite3_column_int(statement, 1)),
                    Int(sqlite3_column_int(statement, 2)))
        }
    }

    private func loadTotals() throws -> [Int: Int] {
        try withStatement("SELECT statement, total FROM tasbeeh_totals") { statement in
            var totals: [Int: Int] = [:]
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                totals[Int(sqlite3_column_int(statement, 0))] = Int(sqlite3_column_int(statement, 1))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw databaseError() }
            return totals
        }
    }

    private enum Value {
        case real(Double), integer(Int32)
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
            case .real(let number): result = sqlite3_bind_double(statement, index, number)
            case .integer(let number): result = sqlite3_bind_int(statement, index, number)
            }
            guard result == SQLITE_OK else { throw databaseError() }
        }
    }

    private func databaseError() -> NSError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open the tasbeeh database."
        return NSError(domain: "Sobha.SQLite", code: Int(sqlite3_errcode(database)),
                       userInfo: [NSLocalizedDescriptionKey: message])
    }
}
