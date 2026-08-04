import XCTest
@testable import PagerCore

final class DropPayloadClassifierTests: XCTestCase {
    let png = TestImageFactory.png(width: 50, height: 50)

    func testImageBeatsString() {
        let payload = DropPayloadClassifier.classify(imageDatas: [png], strings: ["hello"])
        XCTAssertEqual(payload, .image(png))
    }

    func testFirstDecodableImageWins() {
        let payload = DropPayloadClassifier.classify(
            imageDatas: [Data("junk".utf8), png], strings: [])
        XCTAssertEqual(payload, .image(png))
    }

    func testStringFallback() {
        let payload = DropPayloadClassifier.classify(
            imageDatas: [Data("junk".utf8)], strings: ["dropped text"])
        XCTAssertEqual(payload, .text("dropped text"))
    }

    func testBlankStringsSkipped() {
        let payload = DropPayloadClassifier.classify(imageDatas: [], strings: ["  \n", "real"])
        XCTAssertEqual(payload, .text("real"))
    }

    func testLongTextTruncatedToCap() {
        let long = String(repeating: "x", count: 900)
        let payload = DropPayloadClassifier.classify(imageDatas: [], strings: [long])
        XCTAssertEqual(payload, .text(String(repeating: "x", count: EditorSession.maxLength)))
    }

    func testNothingUsableReturnsNil() {
        XCTAssertNil(DropPayloadClassifier.classify(imageDatas: [Data("junk".utf8)], strings: ["   "]))
        XCTAssertNil(DropPayloadClassifier.classify(imageDatas: [], strings: []))
    }
}
