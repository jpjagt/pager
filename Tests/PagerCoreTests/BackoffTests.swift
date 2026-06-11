import XCTest
@testable import PagerCore

final class BackoffTests: XCTestCase {
    func testDoublesFromOneSecondAndCapsAtThirty() {
        var backoff = Backoff()
        XCTAssertEqual(backoff.nextDelay(), 1)
        XCTAssertEqual(backoff.nextDelay(), 2)
        XCTAssertEqual(backoff.nextDelay(), 4)
        XCTAssertEqual(backoff.nextDelay(), 8)
        XCTAssertEqual(backoff.nextDelay(), 16)
        XCTAssertEqual(backoff.nextDelay(), 30)
        XCTAssertEqual(backoff.nextDelay(), 30)
    }

    func testResetStartsOver() {
        var backoff = Backoff()
        _ = backoff.nextDelay()
        _ = backoff.nextDelay()
        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(), 1)
    }
}
