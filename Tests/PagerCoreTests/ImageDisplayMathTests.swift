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

    // MARK: containerLayout (popover: full-width padded container, native-size image)

    func testContainerSmallImageDisplaysAtNativeSizeInMinHeightBox() {
        // 40×40 px = 20×20 pt at Retina scale; container pads out to the 60pt floor.
        let layout = ImageDisplayMath.containerLayout(
            imagePixelSize: CGSize(width: 40, height: 40), containerWidth: 328)
        XCTAssertEqual(layout.imageSize, CGSize(width: 20, height: 20))
        XCTAssertEqual(layout.containerSize, CGSize(width: 328, height: 60))
    }

    func testContainerShortWideImageGetsMinHeight() {
        // 300×50 px = 150×25 pt: fits at native size, 60pt height floor applies.
        let layout = ImageDisplayMath.containerLayout(
            imagePixelSize: CGSize(width: 300, height: 50), containerWidth: 328)
        XCTAssertEqual(layout.imageSize, CGSize(width: 150, height: 25))
        XCTAssertEqual(layout.containerSize.height, 60)
    }

    func testContainerWideImageScalesDownToContentWidth() {
        // 2048×1024 px = 1024×512 pt natural → scaled to the 322pt content width.
        let layout = ImageDisplayMath.containerLayout(
            imagePixelSize: CGSize(width: 2048, height: 1024), containerWidth: 328)
        XCTAssertEqual(layout.imageSize.width, 322, accuracy: 0.5)
        XCTAssertEqual(layout.imageSize.height, 161, accuracy: 0.5)
        XCTAssertEqual(layout.containerSize, CGSize(width: 328, height: layout.imageSize.height + 6))
    }

    func testContainerVeryTallImageClampedToNineSixteenBox() {
        // 450×1800 px = 225×900 pt natural. The container is capped at 9:16
        // (328 → 583.1pt tall); the image scales to fit the content height.
        let layout = ImageDisplayMath.containerLayout(
            imagePixelSize: CGSize(width: 450, height: 1800), containerWidth: 328)
        let maxContainerHeight = 328.0 * 16.0 / 9.0
        XCTAssertEqual(layout.containerSize.height, maxContainerHeight, accuracy: 0.5)
        XCTAssertEqual(layout.imageSize.height, maxContainerHeight - 6, accuracy: 0.5)
        XCTAssertLessThan(layout.imageSize.width, 328 - 6)
    }

    func testContainerNeverUpscales() {
        // 200×100 px = 100×50 pt — displayed exactly at natural size.
        let layout = ImageDisplayMath.containerLayout(
            imagePixelSize: CGSize(width: 200, height: 100), containerWidth: 328)
        XCTAssertEqual(layout.imageSize, CGSize(width: 100, height: 50))
    }

    func testContainerDegenerateInputsReturnZero() {
        XCTAssertEqual(
            ImageDisplayMath.containerLayout(imagePixelSize: .zero, containerWidth: 328),
            ImageDisplayMath.ContainerLayout(containerSize: .zero, imageSize: .zero))
        XCTAssertEqual(
            ImageDisplayMath.containerLayout(
                imagePixelSize: CGSize(width: 10, height: 10), containerWidth: 0),
            ImageDisplayMath.ContainerLayout(containerSize: .zero, imageSize: .zero))
    }
}
