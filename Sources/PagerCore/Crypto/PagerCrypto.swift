import Foundation
import CryptoKit

/// Derives the DB path and AES key from a share code (HKDF-SHA256, independent
/// info strings) and seals/opens the pager text with AES-256-GCM.
public struct PagerCrypto {
    /// Hex id used as /pagers/{pathId}. One-way: the server learns nothing from it.
    public let pathId: String
    private let key: SymmetricKey

    public init(code: ShareCode) {
        let ikm = SymmetricKey(data: Data(code.entropy.utf8))
        let pathKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, info: Data("bffpager:path".utf8), outputByteCount: 16)
        pathId = pathKey.withUnsafeBytes { Data($0) }
            .map { String(format: "%02x", $0) }.joined()
        key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, info: Data("bffpager:key".utf8), outputByteCount: 32)
    }

    /// Returns base64(nonce ‖ ciphertext ‖ tag).
    public func encrypt(_ text: String) throws -> String {
        let sealed = try AES.GCM.seal(Data(text.utf8), using: key)
        return sealed.combined!.base64EncodedString()
    }

    /// nil on any corruption/tampering/wrong key — caller keeps last good text.
    public func decrypt(_ ct: String) -> String? {
        guard let data = Data(base64Encoded: ct),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key)
        else { return nil }
        return String(data: plain, encoding: .utf8)
    }
}
