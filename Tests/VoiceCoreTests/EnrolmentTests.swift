import XCTest
import Security
@testable import VoiceCore

/// In-memory `IdentityStoring`: real EC keys, nothing touches the Keychain.
final class EphemeralIdentityStore: IdentityStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: SecKey] = [:]
    private(set) var storedCertificates: [(der: Data, deviceId: String)] = []
    private(set) var retags: [(from: String, to: String)] = []

    var keysCreated: Int {
        lock.lock()
        defer { lock.unlock() }
        return keys.count
    }

    func privateKey(deviceId: String) throws -> SecKey {
        lock.lock()
        defer { lock.unlock() }
        if let existing = keys[deviceId] { return existing }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
        keys[deviceId] = key
        return key
    }

    func publicKeyBytes(of privateKey: SecKey) throws -> Data {
        SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(privateKey)!, nil)! as Data
    }

    func signer(privateKey: SecKey) -> (Data) throws -> Data {
        { message in
            SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256,
                                  message as CFData, nil)! as Data
        }
    }

    func storeCertificate(_ der: Data, deviceId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storedCertificates.append((der, deviceId))
    }

    func retagKey(fromDeviceId: String, toDeviceId: String) {
        lock.lock()
        defer { lock.unlock() }
        retags.append((fromDeviceId, toDeviceId))
        keys[toDeviceId] = keys.removeValue(forKey: fromDeviceId)
    }

    func identity(deviceId: String) -> SecIdentity? { nil }
    func removeIdentity(deviceId: String) {}
}

/// Scripted `EnrolmentTransport` recording every call with its trust policy.
final class FakeEnrolmentTransport: EnrolmentTransport, @unchecked Sendable {
    struct Call {
        var url: URL
        var body: [String: Any]?
        var trust: ServerTrust
    }

    private let lock = NSLock()
    private(set) var calls: [Call] = []
    var caResponse: (Data, Int) = (Data(), 200)
    var provisionResponse: (Data, Int) = (Data(), 200)

    func get(_ url: URL, trust: ServerTrust) async throws -> (Data, Int) {
        lock.lock()
        calls.append(Call(url: url, body: nil, trust: trust))
        defer { lock.unlock() }
        return caResponse
    }

    func post(_ url: URL, json: Data, trust: ServerTrust) async throws -> (Data, Int) {
        lock.lock()
        let body = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
        calls.append(Call(url: url, body: body, trust: trust))
        defer { lock.unlock() }
        return provisionResponse
    }
}

@MainActor
final class EnrolmentTests: XCTestCase {
    private var suiteName: String!
    private var circles: CircleStore!
    private var identityStore: EphemeralIdentityStore!
    private var transport: FakeEnrolmentTransport!

    private let caDER = Data([0x30, 0x82, 0x01, 0x02, 0xAA, 0xBB]) // stand-in "cert"
    private let certDER = Data([0x30, 0x82, 0x02, 0x03, 0xCC])
    private var caPEM: String { PEM.encode(caDER, label: "CERTIFICATE") }
    private var fingerprint: String { PEM.fingerprint(der: caDER) }

    override func setUp() {
        super.setUp()
        suiteName = "voice-enrol-\(UUID().uuidString)"
        circles = CircleStore(defaults: UserDefaults(suiteName: suiteName)!)
        identityStore = EphemeralIdentityStore()
        transport = FakeEnrolmentTransport()
        transport.caResponse = (Data(caPEM.utf8), 200)
        transport.provisionResponse = (bundleJSON(), 200)
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func bundleJSON(cert: Bool = true) -> Data {
        var bundle: [String: Any] = [
            "device_id": "vpd-3fa2c81b",
            "user_id": "usr-a41f09c2",
            "circle_id": "cir-77b0e4d9",
            "members": [["user_id": "usr-f", "devices": ["vpd-f1", "vpd-f2"], "name": "Friend"]],
            "endpoints": [
                "relay": "https://relay.example",
                "mqtt": ["host": "broker.example", "port": 8883],
            ],
        ]
        if cert {
            bundle["cert"] = PEM.encode(certDER, label: "CERTIFICATE")
            bundle["ca"] = caPEM
        }
        return try! JSONSerialization.data(withJSONObject: bundle)
    }

    private func client() -> ProvisioningClient {
        ProvisioningClient(transport: transport)
    }

    func testEnrolHappyPathFollowsClientMD() async throws {
        let circle = try await VoiceActions.enroll(
            serverURL: "https://voice.example", claimToken: "tok",
            caFingerprint: fingerprint.uppercased(), // case-insensitive
            circles: circles, identityStore: identityStore, client: client())

        // Call order and trust policies.
        XCTAssertEqual(transport.calls.count, 2)
        XCTAssertEqual(transport.calls[0].url.path, "/v1/ca")
        XCTAssertEqual(transport.calls[0].trust, .acceptAny)
        XCTAssertEqual(transport.calls[1].url.path, "/v1/provision")
        XCTAssertEqual(transport.calls[1].trust, .pinned([caDER]))

        // Request shape: {claim_token, csr PEM} and nothing else identifying.
        let body = transport.calls[1].body!
        XCTAssertEqual(body["claim_token"] as? String, "tok")
        let csr = body["csr"] as? String ?? ""
        XCTAssertTrue(csr.hasPrefix("-----BEGIN CERTIFICATE REQUEST-----"))
        XCTAssertNil(body["device_id"], "identity is the token's, not the client's")

        // Persisted results.
        XCTAssertEqual(circle.config.deviceId, "vpd-3fa2c81b")
        XCTAssertEqual(circle.config.brokerHost, "broker.example")
        XCTAssertEqual(circle.config.relayURL.absoluteString, "https://relay.example")
        XCTAssertEqual(circle.config.userId(forDevice: "vpd-f2"), "usr-f")
        XCTAssertNil(circle.config.devClientCN)
        XCTAssertEqual(circle.caBundle, [caDER])
        XCTAssertEqual(identityStore.storedCertificates.first?.der, certDER)
        XCTAssertEqual(identityStore.storedCertificates.first?.deviceId, "vpd-3fa2c81b")
        XCTAssertEqual(identityStore.retags.first?.to, "vpd-3fa2c81b",
                       "key re-homed under the granted id")
    }

    func testFingerprintMismatchAbortsBeforeTokenOrKeygen() async {
        do {
            _ = try await VoiceActions.enroll(
                serverURL: "https://voice.example", claimToken: "tok",
                caFingerprint: "deadbeef", circles: circles,
                identityStore: identityStore, client: client())
            XCTFail("expected mismatch")
        } catch let VoiceActions.EnrollError.fingerprintMismatch(_, actual) {
            XCTAssertEqual(actual, fingerprint)
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(transport.calls.count, 1, "the token was never sent")
        XCTAssertEqual(identityStore.keysCreated, 0, "no key before the gate")
        XCTAssertTrue(circles.circles.isEmpty)
    }

    func testDevEnrolmentPicksIdsAndSetsClientCN() async throws {
        transport.provisionResponse = ({
            var bundle = try! JSONSerialization.jsonObject(with: bundleJSON(cert: false))
                as! [String: Any]
            bundle["device_id"] = "vpd-devpick"
            return try! JSONSerialization.data(withJSONObject: bundle)
        }(), 200)

        let circle = try await VoiceActions.enrollDev(
            serverURL: "http://localhost:8080", circleId: "cir-test",
            userId: "usr-me", circles: circles, client: client())

        XCTAssertEqual(transport.calls.count, 1)
        XCTAssertEqual(transport.calls[0].trust, .system)
        let body = transport.calls[0].body!
        XCTAssertEqual(body["circle_id"] as? String, "cir-test")
        XCTAssertEqual(body["user_id"] as? String, "usr-me")
        XCTAssertTrue((body["device_id"] as? String ?? "").hasPrefix("vpd-"))
        XCTAssertNil(body["csr"], "dev mode sends no CSR")
        XCTAssertEqual(circle.config.devClientCN, "vpd-devpick")
        XCTAssertTrue(circle.caBundle.isEmpty)
        XCTAssertEqual(identityStore.keysCreated, 0, "dev mode mints no keys")
    }

    func testRejectedTokenSurfacesStatus() async {
        transport.provisionResponse = (Data(), 403)
        do {
            _ = try await VoiceActions.enroll(
                serverURL: "https://voice.example", claimToken: "bad",
                caFingerprint: fingerprint, circles: circles,
                identityStore: identityStore, client: client())
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? ProvisioningError, .rejected(status: 403))
        }
    }

    func testMemberDevicesKeyDecodes() throws {
        let bundle = try JSONDecoder().decode(ProvisionBundle.self, from: bundleJSON())
        XCTAssertEqual(bundle.members.first?.deviceIds, ["vpd-f1", "vpd-f2"])
        XCTAssertEqual(bundle.endpoints.mqtt.port, 8883)
    }
}
