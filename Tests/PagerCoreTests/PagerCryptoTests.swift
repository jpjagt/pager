import XCTest
@testable import PagerCore

final class PagerCryptoTests: XCTestCase {
    let code = ShareCode(entropy: "ABCDEFGHJKMNPQ")

    func testDerivationIsDeterministic() {
        let a = PagerCrypto(code: code)
        let b = PagerCrypto(code: code)
        XCTAssertEqual(a.pathId, b.pathId)
        XCTAssertEqual(a.pathId.count, 32) // 16 bytes hex
        XCTAssertTrue(a.pathId.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testDifferentCodesGiveDifferentPaths() {
        let other = PagerCrypto(code: ShareCode(entropy: "ABCDEFGHJKMNP0"))
        XCTAssertNotEqual(PagerCrypto(code: code).pathId, other.pathId)
    }

    func testEncryptDecryptRoundTrip() throws {
        let crypto = PagerCrypto(code: code)
        let ct = try crypto.encrypt("hello 📟 friend")
        XCTAssertEqual(crypto.decrypt(ct), "hello 📟 friend")
    }

    func testEncryptIsNonDeterministic() throws {
        let crypto = PagerCrypto(code: code)
        XCTAssertNotEqual(try crypto.encrypt("x"), try crypto.encrypt("x")) // fresh nonce
    }

    func testDecryptWithWrongKeyFails() throws {
        let ct = try PagerCrypto(code: code).encrypt("secret")
        let wrong = PagerCrypto(code: ShareCode(entropy: "ABCDEFGHJKMNP0"))
        XCTAssertNil(wrong.decrypt(ct))
    }

    func testDecryptGarbageFails() {
        let crypto = PagerCrypto(code: code)
        XCTAssertNil(crypto.decrypt("not base64!!"))
        XCTAssertNil(crypto.decrypt(Data("tooshort".utf8).base64EncodedString()))
    }
}
