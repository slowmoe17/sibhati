import Foundation

/// One statement in the tasbeeh cycle. The cycle repeats in this order.
public enum TasbeehStatement: Int, Codable, CaseIterable, Identifiable {
    case subhanAllah = 0
    case alhamdulillah = 1
    case allahuAkbar = 2

    public var id: Int { rawValue }

    public var text: String {
        switch self {
        case .subhanAllah: return "سبحان الله"
        case .alhamdulillah: return "الحمد لله"
        case .allahuAkbar: return "الله أكبر"
        }
    }

    /// Bundle resource base name for the spoken announcement (.m4a).
    public var audioFileName: String {
        switch self {
        case .subhanAllah: return "subhan_allah"
        case .alhamdulillah: return "alhamdulillah"
        case .allahuAkbar: return "allahu_akbar"
        }
    }

    public var next: TasbeehStatement {
        TasbeehStatement(rawValue: (rawValue + 1) % TasbeehStatement.allCases.count) ?? .subhanAllah
    }
}

/// The persisted counter state. Statement keys stay Ints so stored data does not depend on enum order.
public struct TasbeehSnapshot: Equatable {
    public var target: Int
    public var statementIndex: Int
    public var countInRound: Int
    public var totals: [Int: Int]

    public init(target: Int, statementIndex: Int, countInRound: Int, totals: [Int: Int]) {
        self.target = target
        self.statementIndex = statementIndex
        self.countInRound = countInRound
        self.totals = totals
    }
}

/// Pure counter state machine: taps, rounds of 33/99, per-statement totals. No I/O.
public struct TasbeehCounter: Equatable {
    public static let allowedTargets = [33, 99]

    public private(set) var target: Int
    public private(set) var statement: TasbeehStatement
    public private(set) var countInRound: Int
    public private(set) var totals: [TasbeehStatement: Int]

    public var grandTotal: Int { totals.values.reduce(0, +) }
    public var progress: Double { target > 0 ? Double(countInRound) / Double(target) : 0 }

    public enum Event: Equatable {
        case counted
        case roundCompleted(finished: TasbeehStatement, next: TasbeehStatement)
    }

    public init(target: Int = 33) {
        self.target = target
        statement = .subhanAllah
        countInRound = 0
        totals = [:]
    }

    public init(snapshot: TasbeehSnapshot) {
        target = snapshot.target
        statement = TasbeehStatement(rawValue: snapshot.statementIndex) ?? .subhanAllah
        countInRound = snapshot.countInRound
        totals = Dictionary(uniqueKeysWithValues: snapshot.totals.compactMap { index, total in
            TasbeehStatement(rawValue: index).map { ($0, total) }
        })
    }

    public var snapshot: TasbeehSnapshot {
        TasbeehSnapshot(
            target: target, statementIndex: statement.rawValue, countInRound: countInRound,
            totals: Dictionary(uniqueKeysWithValues: totals.map { ($0.key.rawValue, $0.value) })
        )
    }

    @discardableResult
    public mutating func increment() -> Event {
        countInRound += 1
        totals[statement, default: 0] += 1
        guard countInRound >= target else { return .counted }
        let finished = statement
        statement = statement.next
        countInRound = 0
        return .roundCompleted(finished: finished, next: statement)
    }
}
