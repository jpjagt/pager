import XCTest
@testable import PagerCore

final class ImageCodecTests: XCTestCase {
    func testProcessDownscalesLargeImage() throws {
        let jpeg = try ImageCodec.process(TestImageFactory.png(width: 3000, height: 2000))
        let size = try XCTUnwrap(ImageCodec.pixelSize(of: jpeg))
        XCTAssertLessThanOrEqual(max(size.width, size.height), 1024)
        XCTAssertLessThanOrEqual(jpeg.count, ImageCodec.maxEncodedBytes)
    }

    func testProcessKeepsSmallImageDimensions() throws {
        let jpeg = try ImageCodec.process(TestImageFactory.png(width: 200, height: 100))
        let size = try XCTUnwrap(ImageCodec.pixelSize(of: jpeg))
        // Thumbnailing must not upscale a small image.
        XCTAssertLessThanOrEqual(max(size.width, size.height), 200)
    }

    func testProcessOutputIsDecodableImage() throws {
        let jpeg = try ImageCodec.process(TestImageFactory.png(width: 640, height: 480))
        XCTAssertTrue(ImageCodec.isDecodableImage(jpeg))
    }

    func testProcessRejectsNonImageData() {
        XCTAssertThrowsError(try ImageCodec.process(Data("not an image".utf8))) { error in
            XCTAssertEqual(error as? ImageCodecError, .notAnImage)
        }
    }

    func testIsDecodableImage() {
        XCTAssertTrue(ImageCodec.isDecodableImage(TestImageFactory.png(width: 10, height: 10)))
        XCTAssertFalse(ImageCodec.isDecodableImage(Data("garbage".utf8)))
        XCTAssertFalse(ImageCodec.isDecodableImage(Data()))
    }

    func testPixelSize() {
        let size = ImageCodec.pixelSize(of: TestImageFactory.png(width: 123, height: 45))
        XCTAssertEqual(size, CGSize(width: 123, height: 45))
    }
}
