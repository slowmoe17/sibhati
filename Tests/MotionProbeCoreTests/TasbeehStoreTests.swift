import Foundation
import XCTest
import MotionProbeCore

final class TasbeehStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testLoadReturnsNilWhenNothingWasSaved() throws {
        let store = try TasbeehStore(url: directory.appendingPathComponent("tasbeeh.sqlite"))
        XCTAssertNil(try store.load())
    }

    func testSnapshotSurvivesClosingAndReopeningTheDatabase() throws {
        let database = directory.appendingPathComponent("tasbeeh.sqlite")
        let snapshot = TasbeehSnapshot(target: 99, statementIndex: 1, countInRound: 12,
                                       totals: [0: 99, 1: 12])
        do {
            let store = try TasbeehStore(url: database)
            try store.save(snapshot)
        }
        let reopened = try TasbeehStore(url: database)
        XCTAssertEqual(try reopened.load(), snapshot)
    }

    func testLaterSaveOverwritesTheEarlierState() throws {
        let store = try TasbeehStore(url: directory.appendingPathComponent("tasbeeh.sqlite"))
        try store.save(TasbeehSnapshot(target: 33, statementIndex: 0, countInRound: 5, totals: [0: 5]))
        try store.save(TasbeehSnapshot(target: 33, statementIndex: 0, countInRound: 6, totals: [0: 6]))
        XCTAssertEqual(try store.load()?.countInRound, 6)
        XCTAssertEqual(try store.load()?.totals, [0: 6])
    }

    func testClearRemovesStateAndTotals() throws {
        let store = try TasbeehStore(url: directory.appendingPathComponent("tasbeeh.sqlite"))
        try store.save(TasbeehSnapshot(target: 33, statementIndex: 2, countInRound: 9,
                                       totals: [0: 33, 1: 33, 2: 9]))
        try store.clear()
        XCTAssertNil(try store.load())
    }
}
