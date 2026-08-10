import Foundation
import Security

/// What enrolment needs from identity storage — a seam so the flow is
/// testable with ephemeral (non-Keychain) keys.
public protocol IdentityStoring: Sendable {
    func privateKey(deviceId: String) throws -> SecKey
    func publicKeyBytes(of privateKey: SecKey) throws -> Data
    func signer(privateKey: SecKey) -> (Data) throws -> Data
    func storeCertificate(_ der: Data, deviceId: String) throws
    /// Moves a key minted under a provisional tag to the granted device id.
    func retagKey(fromDeviceId: String, toDeviceId: String)
    func identity(deviceId: String) -> SecIdentity?
    func removeIdentity(deviceId: String)
}

/// The device identity, Keychain-backed: a P-256 private key generated
/// in-place (it never leaves the Mac — same property the pendant gets from
/// its on-chip keypair) and the CA-issued certificate next to it, findable
/// as a `SecIdentity` for both TLS stacks.
///
/// Identities are keyed by the client's `device_id` — minted before
/// provisioning, so the key can exist before the circle does.
///
/// Thin by design — decisions live in callers; this file is unit-untested
/// (it touches the real Keychain) and exercised by e2e and the app.
public final class KeychainIdentityStore: IdentityStoring, @unchecked Sendable {
    private let tagPrefix: String

    public init(tagPrefix: String = "dev.july.pager.voice") {
        self.tagPrefix = tagPrefix
    }

    private func keyTag(_ deviceId: String) -> Data {
        Data("\(tagPrefix).\(deviceId)".utf8)
    }

    private func label(_ deviceId: String) -> String {
        "\(tagPrefix).\(deviceId)"
    }

    /// Generates (or returns the existing) private key for a device id.
    public func privateKey(deviceId: String) throws -> SecKey {
        if let existing = findKey(deviceId: deviceId) { return existing }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag(deviceId),
            ],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return key
    }

    private func findKey(deviceId: String) -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag(deviceId),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return (item as! SecKey)
    }

    /// The uncompressed public point (0x04‖X‖Y) for the CSR.
    public func publicKeyBytes(of privateKey: SecKey) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw CSRBuilder.CSRError.malformedPublicKey
        }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(publicKey, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return data as Data
    }

    /// ECDSA-SHA256 over arbitrary bytes — the CSR's signing seam.
    public func signer(privateKey: SecKey) -> (Data) throws -> Data {
        { message in
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(
                privateKey, .ecdsaSignatureMessageX962SHA256,
                message as CFData, &error) else {
                throw error!.takeRetainedValue() as Error
            }
            return signature as Data
        }
    }

    /// Stores the issued certificate; afterwards `identity(deviceId:)`
    /// resolves because key and certificate sit in the same Keychain.
    public func storeCertificate(_ der: Data, deviceId: String) throws {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw ProvisioningError.malformedResponse
        }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: label(deviceId),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    /// The mTLS client identity for a device id, or nil before provisioning.
    public func identity(deviceId: String) -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label(deviceId),
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return (item as! SecIdentity)
    }

    /// The key is generated before the server allocates the real device id
    /// (the CSR needs it); once the id is granted, the key moves under it so
    /// `removeIdentity` can always find the pair.
    public func retagKey(fromDeviceId: String, toDeviceId: String) {
        guard fromDeviceId != toDeviceId else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag(fromDeviceId),
        ]
        let update: [String: Any] = [
            kSecAttrApplicationTag as String: keyTag(toDeviceId),
        ]
        SecItemUpdate(query as CFDictionary, update as CFDictionary)
    }

    /// Unlinking a circle removes its device's key and certificate.
    public func removeIdentity(deviceId: String) {
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag(deviceId),
        ] as CFDictionary)
        SecItemDelete([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label(deviceId),
        ] as CFDictionary)
    }
}
