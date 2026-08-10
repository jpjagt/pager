import Foundation
import Security

/// The device identity, Keychain-backed: a P-256 private key generated
/// in-place (it never leaves the Mac — same property the pendant gets from
/// its on-chip keypair) and the CA-issued certificate next to it, findable
/// as a `SecIdentity` for both TLS stacks.
///
/// Thin by design — decisions live in callers; this file is unit-untested
/// (it touches the real Keychain) and exercised by e2e and the app.
public final class KeychainIdentityStore: @unchecked Sendable {
    private let tagPrefix: String

    public init(tagPrefix: String = "dev.july.pager.voice") {
        self.tagPrefix = tagPrefix
    }

    private func tag(_ circleId: String) -> Data {
        Data("\(tagPrefix).\(circleId)".utf8)
    }

    /// Generates (or returns the existing) private key for a circle.
    public func privateKey(circleId: String) throws -> SecKey {
        if let existing = findKey(circleId: circleId) { return existing }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag(circleId),
            ],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return key
    }

    private func findKey(circleId: String) -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag(circleId),
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

    /// Stores the issued certificate; afterwards `identity(circleId:)`
    /// resolves because key and certificate sit in the same Keychain.
    public func storeCertificate(_ der: Data, circleId: String) throws {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw ProvisioningError.malformedResponse
        }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: "\(tagPrefix).\(circleId)",
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    /// The mTLS client identity for a circle, or nil before provisioning.
    public func identity(circleId: String) -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: "\(tagPrefix).\(circleId)",
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return (item as! SecIdentity)
    }

    /// Unlinking a circle removes its key and certificate.
    public func removeIdentity(circleId: String) {
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag(circleId),
        ] as CFDictionary)
        SecItemDelete([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: "\(tagPrefix).\(circleId)",
        ] as CFDictionary)
    }
}
