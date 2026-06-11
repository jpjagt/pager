import XCTest
@testable import PagerCore

final class TextUtilTests: XCTestCase {
    func testDetectsURLsWithRanges() {
        let text = "see https://july.dev/bff-pager ok"
        let matches = TextUtil.detectURLs(in: text)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].url.absoluteString, "https://july.dev/bff-pager")
        XCTAssertEqual((text as NSString).substring(with: matches[0].range),
                       "https://july.dev/bff-pager")
    }

    func testNoURLs() {
        XCTAssertTrue(TextUtil.detectURLs(in: "plain text 📟").isEmpty)
    }

    func testColorHexRoundTrip() {
        let color = TextUtil.color(fromHex: "#3366FF")
        XCTAssertNotNil(color)
        XCTAssertEqual(TextUtil.hex(from: color!), "#3366FF")
    }

    func testInvalidHexReturnsNil() {
        XCTAssertNil(TextUtil.color(fromHex: "nope"))
        XCTAssertNil(TextUtil.color(fromHex: "#12"))
    }
}
