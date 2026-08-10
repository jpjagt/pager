import Foundation

/// Builds a PKCS#10 certificate signing request for an EC P-256 key, with
/// the device id as the subject Common Name — the field the provisioning CA
/// copies into the certificate, and the server later reads as the peer's
/// identity (protocol §4).
///
/// The signature is a seam: the caller passes "sign these bytes with the
/// private key" (SecKey ECDSA-SHA256 in the app; anything deterministic in
/// tests). The private key itself never comes near this code.
public enum CSRBuilder {
    public enum CSRError: Error {
        case malformedPublicKey
    }

    /// `publicKey` is the uncompressed EC point (0x04‖X‖Y, 65 bytes) —
    /// exactly what `SecKeyCopyExternalRepresentation` returns for P-256.
    /// `sign` must produce a DER-encoded ECDSA-Sig-Value over its input
    /// (SecKey's `.ecdsaSignatureMessageX962SHA256` does).
    public static func build(commonName: String, publicKey: Data,
                             sign: (Data) throws -> Data) throws -> Data {
        guard publicKey.count == 65, publicKey.first == 0x04 else {
            throw CSRError.malformedPublicKey
        }

        let ecPublicKey = DER.objectIdentifier([1, 2, 840, 10045, 2, 1])
        let prime256v1 = DER.objectIdentifier([1, 2, 840, 10045, 3, 1, 7])
        let ecdsaWithSHA256 = DER.objectIdentifier([1, 2, 840, 10045, 4, 3, 2])
        let commonNameOID = DER.objectIdentifier([2, 5, 4, 3])

        let subject = DER.sequence([
            DER.set([
                DER.sequence([commonNameOID, DER.utf8String(commonName)]),
            ]),
        ])
        let subjectPKInfo = DER.sequence([
            DER.sequence([ecPublicKey, prime256v1]),
            DER.bitString(publicKey),
        ])
        let info = DER.sequence([
            DER.integer(0), // version
            subject,
            subjectPKInfo,
            DER.contextConstructed(0, Data()), // attributes: none
        ])

        let signature = try sign(info)
        return DER.sequence([
            info,
            DER.sequence([ecdsaWithSHA256]),
            DER.bitString(signature),
        ])
    }
}
