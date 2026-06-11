import XCTest
@testable import PagerCore

final class FirebaseClientTests: XCTestCase {
    let client = FirebaseClient(baseURL: URL(string: "https://example-rtdb.firebasedatabase.app")!)

    func testNodeURL() {
        XCTAssertEqual(
            client.nodeURL(pathId: "abc123").absoluteString,
            "https://example-rtdb.firebasedatabase.app/pagers/abc123.json")
    }

    func testPutBodyIncludesServerTimestampPlaceholder() throws {
        let value = PagerValue(ct: "CT", writtenAt: 42, updatedBy: "dev-1")
        let body = try FirebaseClient.putBody(for: value)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["ct"] as? String, "CT")
        XCTAssertEqual(obj["writtenAt"] as? Int64, 42)
        XCTAssertEqual(obj["updatedBy"] as? String, "dev-1")
        XCTAssertEqual(obj["updatedAt"] as? [String: String], [".sv": "timestamp"])
    }
}
