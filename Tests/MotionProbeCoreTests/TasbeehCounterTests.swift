import XCTest
import MotionProbeCore

final class TasbeehCounterTests: XCTestCase {
    func testIncrementCountsWithinTheRound() throws {
        var counter = TasbeehCounter(target: 33)
        XCTAssertEqual(counter.increment(), .counted)
        XCTAssertEqual(counter.increment(), .counted)
        XCTAssertEqual(counter.countInRound, 2)
        XCTAssertEqual(counter.statement, .subhanAllah)
        XCTAssertEqual(counter.grandTotal, 2)
    }

    func testReachingTheTargetCompletesTheRoundAndAdvancesTheStatement() throws {
        var counter = TasbeehCounter(target: 33)
        for _ in 1..<33 {
            XCTAssertEqual(counter.increment(), .counted)
        }
        let event = counter.increment()
        XCTAssertEqual(event, .roundCompleted(finished: .subhanAllah, next: .alhamdulillah))
        XCTAssertEqual(counter.statement, .alhamdulillah)
        XCTAssertEqual(counter.countInRound, 0)
        XCTAssertEqual(counter.totals[.subhanAllah], 33)
    }

    func testFullCycleReturnsToTheFirstStatement() throws {
        var counter = TasbeehCounter(target: 99)
        for _ in 0..<(99 * 3) {
            _ = counter.increment()
        }
        XCTAssertEqual(counter.statement, .subhanAllah)
        XCTAssertEqual(counter.countInRound, 0)
        XCTAssertEqual(counter.totals[.subhanAllah], 99)
        XCTAssertEqual(counter.totals[.alhamdulillah], 99)
        XCTAssertEqual(counter.totals[.allahuAkbar], 99)
        XCTAssertEqual(counter.grandTotal, 297)
    }

    func testSnapshotRoundTripPreservesProgressAndTotals() throws {
        var counter = TasbeehCounter(target: 99)
        for _ in 0..<(99 + 12) { _ = counter.increment() }
        let restored = TasbeehCounter(snapshot: counter.snapshot)
        XCTAssertEqual(restored, counter)
        XCTAssertEqual(restored.statement, .alhamdulillah)
        XCTAssertEqual(restored.countInRound, 12)
        XCTAssertEqual(restored.grandTotal, 111)
    }

    func testStatementCycleOrder() {
        XCTAssertEqual(TasbeehStatement.subhanAllah.next, .alhamdulillah)
        XCTAssertEqual(TasbeehStatement.alhamdulillah.next, .allahuAkbar)
        XCTAssertEqual(TasbeehStatement.allahuAkbar.next, .subhanAllah)
    }
}
