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

    func testColorFromHexDecodesComponents() throws {
        let color = try XCTUnwrap(TextUtil.color(fromHex: "#3366FF"))
        let rgb = color.usingColorSpace(.sRGB)!
        XCTAssertEqual(Int(round(rgb.redComponent * 255)), 0x33)
        XCTAssertEqual(Int(round(rgb.greenComponent * 255)), 0x66)
        XCTAssertEqual(Int(round(rgb.blueComponent * 255)), 0xFF)
    }

    func testInvalidHexReturnsNil() {
        XCTAssertNil(TextUtil.color(fromHex: "nope"))
        XCTAssertNil(TextUtil.color(fromHex: "#12"))
    }
}
