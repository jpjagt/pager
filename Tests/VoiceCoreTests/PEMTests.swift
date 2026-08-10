import XCTest
@testable import VoiceCore

final class PEMTests: XCTestCase {
    func testRoundTrip() {
        let der = Data((0 ..< 200).map { UInt8($0 % 251) })
        let pem = PEM.encode(der, label: "CERTIFICATE")
        XCTAssertTrue(pem.hasPrefix("-----BEGIN CERTIFICATE-----\n"))
        XCTAssertTrue(pem.hasSuffix("-----END CERTIFICATE-----\n"))
        XCTAssertEqual(PEM.decodeAll(pem), [der])
    }

    func testLinesAreWrappedAt64Columns() {
        let pem = PEM.encode(Data(repeating: 0xAB, count: 100), label: "CERTIFICATE REQUEST")
        let lines = pem.split(separator: "\n").dropFirst().dropLast()
        XCTAssertTrue(lines.allSatisfy { $0.count <= 64 })
    }

    func testBundleSplitsIntoAllBlocks() {
        let a = Data([1, 2, 3])
        let b = Data(repeating: 9, count: 80)
        let bundle = PEM.encode(a, label: "CERTIFICATE")
            + "some noise between blocks\n"
            + PEM.encode(b, label: "CERTIFICATE")
        XCTAssertEqual(PEM.decodeAll(bundle), [a, b])
        XCTAssertEqual(PEM.decodeFirst(bundle), a)
    }

    func testMalformedBase64BlockIsSkipped() {
        let pem = "-----BEGIN CERTIFICATE-----\nnot!base64!\n-----END CERTIFICATE-----\n"
        XCTAssertEqual(PEM.decodeAll(pem), [])
    }

    func testFingerprintKnownVector() {
        // SHA-256("abc") — the classic test vector.
        XCTAssertEqual(
            PEM.fingerprint(der: Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testFingerprintCompareIsCaseAndColonInsensitive() {
        let der = Data("abc".utf8)
        XCTAssertTrue(PEM.fingerprintMatches(
            "BA7816BF:8F01CFEA:414140DE:5DAE2223:B00361A3:96177A9C:B410FF61:F20015AD",
            der: der))
        XCTAssertFalse(PEM.fingerprintMatches("deadbeef", der: der))
    }
}
