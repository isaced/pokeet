import XCTest
@testable import Pokeet

final class BubblePagerTests: XCTestCase {
    func testInitialWindowShowsLatestPage() {
        var pager = BubblePager(pageSize: 60)

        pager.reset(total: 145)
        XCTAssertEqual(pager.window(total: 145), 85..<145)
        XCTAssertTrue(pager.window(total: 145).lowerBound > 0)

        pager.reset(total: 10)
        XCTAssertEqual(pager.window(total: 10), 0..<10)
        XCTAssertFalse(pager.window(total: 10).lowerBound > 0)
    }

    func testLoadOlderPagesBackwardsUntilExhausted() {
        var pager = BubblePager(pageSize: 60)
        pager.reset(total: 145)

        XCTAssertTrue(pager.loadOlder(total: 145))
        XCTAssertEqual(pager.window(total: 145), 25..<145)

        XCTAssertTrue(pager.loadOlder(total: 145))
        XCTAssertEqual(pager.window(total: 145), 0..<145)

        XCTAssertFalse(pager.loadOlder(total: 145))
        XCTAssertEqual(pager.window(total: 145), 0..<145)
    }

    func testPageSizeOfOneTerminatesAtZero() {
        var pager = BubblePager(pageSize: 1)
        pager.reset(total: 3)
        XCTAssertEqual(pager.window(total: 3), 2..<3)

        var loads = 0
        while pager.loadOlder(total: 3) {
            loads += 1
            XCTAssertLessThanOrEqual(loads, 3)
        }

        XCTAssertEqual(loads, 2)
        XCTAssertEqual(pager.window(total: 3), 0..<3)
    }

    func testWindowStaysAnchoredToNewestEntryAfterAppends() {
        var pager = BubblePager(pageSize: 60)
        pager.reset(total: 10)
        XCTAssertEqual(pager.window(total: 10), 0..<10)

        pager.reset(total: 80)
        XCTAssertEqual(pager.window(total: 80), 20..<80)
    }

    func testClampKeepsWindowNonEmptyAfterShrink() {
        var pager = BubblePager(pageSize: 60)
        pager.reset(total: 145)

        pager.clamp(total: 80)
        XCTAssertEqual(pager.window(total: 80), 79..<80)

        pager.clamp(total: 0)
        XCTAssertEqual(pager.window(total: 0), 0..<0)
    }
}
