import XCTest
@testable import PagerCore

final class PagerContentCryptoTests: XCTestCase {
    let crypto = PagerCrypto(code: ShareCode.generate())

    func testDataRoundTrip() throws {
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        let ct = try crypto.encryptData(bytes)
        XCTAssertEqual(crypto.decryptData(ct), bytes)
    }

    func testDecryptDataRejectsTampering() throws {
        let ct = try crypto.encryptData(Data([1, 2, 3]))
        var raw = Data(base64Encoded: ct)!
        raw[raw.count - 1] ^= 0xFF
        XCTAssertNil(crypto.decryptData(raw.base64EncodedString()))
    }

    func testPagerValueDecodesWithoutType() throws {
        let json = #"{"ct":"abc","writtenAt":5,"updatedBy":"dev"}"#
        let value = try JSONDecoder().decode(PagerValue.self, from: Data(json.utf8))
        XCTAssertNil(value.type)
    }

    func testPagerValueDecodesWithType() throws {
        let json = #"{"ct":"abc","writtenAt":5,"updatedBy":"dev","type":"img"}"#
        let value = try JSONDecoder().decode(PagerValue.self, from: Data(json.utf8))
        XCTAssertEqual(value.type, "img")
    }

    func testContentAccessors() {
        XCTAssertEqual(PagerContent.text("hi").textValue, "hi")
        XCTAssertEqual(PagerContent.image(Data([1])).textValue, "")
        XCTAssertNil(PagerContent.text("hi").wireType)
        XCTAssertEqual(PagerContent.image(Data([1])).wireType, "img")
        XCTAssertEqual(PagerContent.image(Data([1, 2])).imageData, Data([1, 2]))
        XCTAssertNil(PagerContent.text("hi").imageData)
        XCTAssertTrue(PagerContent.image(Data()).isImage)
        XCTAssertEqual(PagerContent.text("abc").sizeForLog, 3)
        XCTAssertEqual(PagerContent.image(Data([1, 2, 3, 4])).sizeForLog, 4)
    }

    func testEncryptContentTextOmitsType() throws {
        let sealed = try crypto.encryptContent(.text("hello"))
        XCTAssertNil(sealed.type)
        XCTAssertEqual(crypto.decryptContent(ct: sealed.ct, type: sealed.type), .text("hello"))
    }

    func testEncryptContentImageRoundTrip() throws {
        let jpeg = try ImageCodec.process(TestImageFactory.png(width: 300, height: 200))
        let sealed = try crypto.encryptContent(.image(jpeg))
        XCTAssertEqual(sealed.type, "img")
        XCTAssertEqual(crypto.decryptContent(ct: sealed.ct, type: sealed.type), .image(jpeg))
    }

    func testDecryptContentAbsentTypeIsText() throws {
        let ct = try crypto.encrypt("legacy")
        XCTAssertEqual(crypto.decryptContent(ct: ct, type: nil), .text("legacy"))
    }

    func testDecryptContentRejectsImgThatIsNotAnImage() throws {
        // Valid ciphertext of bytes that do not decode as an image.
        let ct = try crypto.encryptData(Data("not a jpeg".utf8))
        XCTAssertNil(crypto.decryptContent(ct: ct, type: "img"))
    }

    func testDecryptContentRejectsTamperedImg() throws {
        let jpeg = try ImageCodec.process(TestImageFactory.png(width: 100, height: 100))
        let ct = try crypto.encryptData(jpeg)
        var raw = Data(base64Encoded: ct)!
        raw[raw.count - 1] ^= 0xFF
        XCTAssertNil(crypto.decryptContent(ct: raw.base64EncodedString(), type: "img"))
    }
}
