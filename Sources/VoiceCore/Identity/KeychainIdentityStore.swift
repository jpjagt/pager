import Foundation
import Security
import CryptoKit

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
    ///
    /// Generates a **permanent** EC key, carrying an ACL that lets any
    /// application sign without a prompt.
    ///
    /// Two non-obvious constraints, both learned the hard way:
    /// - The key MUST be created permanent in one call (`kSecAttrIsPermanent`
    ///   inside `kSecPrivateKeyAttrs`). Creating a transient key and then
    ///   `SecItemAdd`-ing it produces an entry that never pairs with its
    ///   certificate — `SecItemCopyMatching(kSecClassIdentity)` silently
    ///   skips it, so the client falls back to some *other* device's cert.
    /// - Pager is ad-hoc signed, so the default creator-only ACL cannot
    ///   durably recognize the app; every mTLS handshake would raise a
    ///   keychain password dialog and strangle voice traffic. The trust-all
    ///   ACL is the standard trade for an unsigned app doing client TLS.
    public func privateKey(deviceId: String) throws -> SecKey {
        if let existing = findKey(deviceId: deviceId) { return existing }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag(deviceId),
                kSecAttrLabel as String: label(deviceId),
                kSecAttrAccess as String: try promptFreeAccess(label: label(deviceId)),
            ],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return key
    }

    /// A legacy `SecAccess` whose use-key ACLs trust every application with
    /// no prompt selector. The SecAccess API is deprecated but remains the
    /// only way to express this for the file-based login keychain.
    private func promptFreeAccess(label: String) throws -> SecAccess {
        var accessRef: SecAccess?
        let status = SecAccessCreate(label as CFString, [] as CFArray, &accessRef)
        guard status == errSecSuccess, let access = accessRef else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        for authorization in [kSecACLAuthorizationSign, kSecACLAuthorizationAny] {
            guard let acls = SecAccessCopyMatchingACLList(access, authorization)
                    as? [SecACL] else { continue }
            for acl in acls {
                // nil application list = every application; a default prompt
                // selector with no "require passphrase" bits = never ask.
                SecACLSetContents(acl, nil, label as CFString, SecKeychainPromptSelector())
            }
        }
        return access
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
    ///
    /// Resolves by the certificate's **Common Name**, which is the only
    /// authoritative correlation: `kSecAttrLabel` is silently ignored by
    /// `kSecClassIdentity` queries on the macOS file keychain (it returns an
    /// arbitrary identity instead), and the key's application tag is
    /// unreliable after enrolment. The CN is set by the CA to the granted
    /// `device_id`, so enumerating identities and matching CN is exact.
    public func identity(deviceId: String) -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let identities = items as? [SecIdentity] else { return nil }
        return identities.first { identity in
            var cert: SecCertificate?
            SecIdentityCopyCertificate(identity, &cert)
            var cn: CFString?
            if let cert { SecCertificateCopyCommonName(cert, &cn) }
            return (cn as String?) == deviceId
        }
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

    /// Unlinking a circle removes its device's key and certificate. Keyed off
    /// the certificate CN (see `identity`): find the cert, delete its paired
    /// private key by public-key hash, then the cert itself.
    public func removeIdentity(deviceId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let certs = items as? [SecCertificate] else { return }
        for cert in certs {
            var cn: CFString?
            SecCertificateCopyCommonName(cert, &cn)
            guard (cn as String?) == deviceId else { continue }
            if let key = SecCertificateCopyKey(cert),
               let publicKey = SecKeyCopyExternalRepresentation(key, nil) as Data? {
                // The private key shares the public key's SHA-1 (its
                // application label) — the reliable delete predicate.
                let keyHash = Data(Insecure.SHA1.hash(data: publicKey))
                SecItemDelete([
                    kSecClass as String: kSecClassKey,
                    kSecAttrApplicationLabel as String: keyHash,
                ] as CFDictionary)
            }
            SecItemDelete([
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: cert,
            ] as CFDictionary)
        }
    }
}
