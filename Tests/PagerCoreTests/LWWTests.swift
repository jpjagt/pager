import XCTest
@testable import PagerCore

final class LWWTests: XCTestCase {
    func value(_ writtenAt: Int64, by: String = "dev-a") -> PagerValue {
        PagerValue(ct: "ct", writtenAt: writtenAt, updatedBy: by)
    }

    func testAnythingWinsOverNil() {
        XCTAssertTrue(LWW.wins(value(1), over: nil))
    }

    func testNewerWrittenAtWins() {
        XCTAssertTrue(LWW.wins(value(200), over: value(100)))
        XCTAssertFalse(LWW.wins(value(100), over: value(200)))
    }

    func testEqualTimestampBreaksTieByUpdatedBy() {
        XCTAssertTrue(LWW.wins(value(100, by: "b"), over: value(100, by: "a")))
        XCTAssertFalse(LWW.wins(value(100, by: "a"), over: value(100, by: "b")))
        XCTAssertFalse(LWW.wins(value(100, by: "a"), over: value(100, by: "a")))
    }

    func testDecodesFirebaseJSON() throws {
        let json = #"{"ct":"abc","writtenAt":1749632100123,"updatedAt":1749632100500,"updatedBy":"dev-1"}"#
        let v = try JSONDecoder().decode(PagerValue.self, from: Data(json.utf8))
        XCTAssertEqual(v.ct, "abc")
        XCTAssertEqual(v.writtenAt, 1_749_632_100_123)
        XCTAssertEqual(v.updatedAt, 1_749_632_100_500)
        XCTAssertEqual(v.updatedBy, "dev-1")
    }

    func testDecodesWithoutUpdatedAt() throws {
        let json = #"{"ct":"abc","writtenAt":1,"updatedBy":"dev-1"}"#
        let v = try JSONDecoder().decode(PagerValue.self, from: Data(json.utf8))
        XCTAssertNil(v.updatedAt)
    }
}
