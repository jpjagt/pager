import XCTest
import Security
@testable import VoiceCore

final class IdentityTests: XCTestCase {
    /// An ephemeral (non-Keychain) P-256 key — real crypto, no system state.
    private func ephemeralKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return key
    }

    private func buildCSR(commonName: String = "vpd-3fa2c81b") throws -> (csr: Data, key: SecKey) {
        let key = try ephemeralKey()
        let publicKey = SecKeyCopyExternalRepresentation(
            SecKeyCopyPublicKey(key)!, nil)! as Data
        let csr = try CSRBuilder.build(commonName: commonName, publicKey: publicKey) { message in
            SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256,
                                  message as CFData, nil)! as Data
        }
        return (csr, key)
    }

    func testDEREncodingPrimitives() {
        XCTAssertEqual([UInt8](DER.integer(0)), [0x02, 0x01, 0x00])
        XCTAssertEqual([UInt8](DER.objectIdentifier([2, 5, 4, 3])), [0x06, 0x03, 0x55, 0x04, 0x03])
        XCTAssertEqual([UInt8](DER.objectIdentifier([1, 2, 840, 10045, 2, 1])),
                       [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
        XCTAssertEqual([UInt8](DER.length(127)), [0x7F])
        XCTAssertEqual([UInt8](DER.length(128)), [0x81, 0x80])
        XCTAssertEqual([UInt8](DER.length(300)), [0x82, 0x01, 0x2C])
        XCTAssertEqual([UInt8](DER.utf8String("ab")), [0x0C, 0x02, 0x61, 0x62])
    }

    func testCSRSignatureVerifiesWithTheKey() throws {
        let key = try ephemeralKey()
        let publicKeyData = SecKeyCopyExternalRepresentation(
            SecKeyCopyPublicKey(key)!, nil)! as Data
        var signedMessage = Data()
        _ = try CSRBuilder.build(commonName: "vpd-aa", publicKey: publicKeyData) { message in
            signedMessage = message
            return SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256,
                                         message as CFData, nil)! as Data
        }
        // The signed bytes must be the CertificationRequestInfo SEQUENCE.
        XCTAssertEqual(signedMessage.first, 0x30)
        let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256,
                                              signedMessage as CFData, nil)! as Data
        XCTAssertTrue(SecKeyVerifySignature(
            SecKeyCopyPublicKey(key)!, .ecdsaSignatureMessageX962SHA256,
            signedMessage as CFData, signature as CFData, nil))
    }

    func testCSRVerifiesWithOpenSSL() throws {
        let openssl = "/usr/bin/openssl"
        guard FileManager.default.isExecutableFile(atPath: openssl) else {
            throw XCTSkip("no system openssl")
        }
        let (csr, _) = try buildCSR()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).csr")
        try csr.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: openssl)
        process.arguments = ["req", "-in", url.path, "-inform", "DER", "-verify", "-noout",
                             "-subject"]
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile()
                            + stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "openssl rejected the CSR: \(output)")
        XCTAssertTrue(output.contains("vpd-3fa2c81b"), "CN missing from subject: \(output)")
    }

    func testRejectsMalformedPublicKey() {
        XCTAssertThrowsError(try CSRBuilder.build(
            commonName: "vpd-aa", publicKey: Data([0x02, 0x01])) { $0 })
    }

    func testMintedDeviceIdShape() {
        let id = ProvisioningClient.mintDeviceId()
        XCTAssertTrue(id.hasPrefix("vpd-"))
        XCTAssertEqual(id.count, 12)
        XCTAssertTrue(id.dropFirst(4).allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testProvisioningRoundTrip() async throws {
        let response: [String: Any] = [
            "device_id": "vpd-3fa2c81b",
            "user_id": "usr-a41f09c2",
            "certificate": Data([0x30, 0x82]).base64EncodedString(),
            "ca_bundle": [Data([0x30, 0x81]).base64EncodedString()],
            "circle_id": "cir-77b0e4d9",
            "members": [["user_id": "usr-f", "device_ids": ["vpd-f1"], "name": "Friend"]],
            "broker_host": "broker.example",
            "broker_port": 8883,
            "relay_url": "https://relay.example",
        ]
        var captured: (URL, Data)?
        let client = ProvisioningClient { url, body in
            captured = (url, body)
            return (try JSONSerialization.data(withJSONObject: response), 200)
        }
        let result = try await client.provision(
            serverURL: URL(string: "https://voice.example")!,
            claimToken: "tok", requestedDeviceId: "vpd-3fa2c81b", csr: Data([1, 2]))
        XCTAssertEqual(captured?.0.path, "/v1/provision")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(
            with: captured!.1) as? [String: Any])
        XCTAssertEqual(sent["claim_token"] as? String, "tok")
        XCTAssertEqual(result.circleConfig().circleId, "cir-77b0e4d9")
        XCTAssertEqual(result.circleConfig().userId(forDevice: "vpd-f1"), "usr-f")
        XCTAssertEqual(result.caBundle.count, 1)
    }

    func testProvisioningRejectionSurfacesStatus() async {
        let client = ProvisioningClient { _, _ in (Data(), 403) }
        do {
            _ = try await client.provision(
                serverURL: URL(string: "https://voice.example")!,
                claimToken: "bad", requestedDeviceId: "vpd-x", csr: Data())
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? ProvisioningError, .rejected(status: 403))
        }
    }
}
