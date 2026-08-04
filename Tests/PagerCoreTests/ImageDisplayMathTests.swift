import XCTest
@testable import PagerCore

final class ImageDisplayMathTests: XCTestCase {
    func testWideImageFillsWidth() {
        let box = ImageDisplayMath.boxSize(
            imageSize: CGSize(width: 2000, height: 1000), maxWidth: 328, maxHeight: 240)
        XCTAssertEqual(box.width, 328, accuracy: 0.5)
        XCTAssertEqual(box.height, 164, accuracy: 0.5)
    }

    func testSquareImageCappedByHeight() {
        let box = ImageDisplayMath.boxSize(
            imageSize: CGSize(width: 500, height: 500), maxWidth: 328, maxHeight: 240)
        XCTAssertEqual(box.width, 240, accuracy: 0.5)
        XCTAssertEqual(box.height, 240, accuracy: 0.5)
    }

    func testVeryTallImageClampedToNineSixteen() {
        // 1:3 is taller than 9:16 → the BOX stays 9:16; the image letterboxes inside.
        let box = ImageDisplayMath.boxSize(
            imageSize: CGSize(width: 300, height: 900), maxWidth: 328, maxHeight: 240)
        XCTAssertEqual(box.width / box.height, 9.0 / 16.0, accuracy: 0.01)
        XCTAssertEqual(box.height, 240, accuracy: 0.5)
    }

    func testDegenerateInputsReturnZero() {
        XCTAssertEqual(ImageDisplayMath.boxSize(
            imageSize: .zero, maxWidth: 328, maxHeight: 240), .zero)
        XCTAssertEqual(ImageDisplayMath.boxSize(
            imageSize: CGSize(width: 10, height: 10), maxWidth: 0, maxHeight: 240), .zero)
    }
}
