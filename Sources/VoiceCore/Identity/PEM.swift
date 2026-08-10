import Foundation
import CryptoKit

/// PEM armor, as CLIENT.md's credential bundle uses it: CSRs go out PEM, the
/// certificate and (possibly multi-cert) CA bundle come back PEM, and the CA
/// is identified by the SHA-256 fingerprint of its DER.
public enum PEM {
    /// Wraps DER in armor: `-----BEGIN <label>-----` … 64-column base64 … end.
    public static func encode(_ der: Data, label: String) -> String {
        let base64 = der.base64EncodedString()
        let wrapped = stride(from: 0, to: base64.count, by: 64).map { offset -> Substring in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(start, offsetBy: 64, limitedBy: base64.endIndex)
                ?? base64.endIndex
            return base64[start ..< end]
        }.joined(separator: "\n")
        return "-----BEGIN \(label)-----\n\(wrapped)\n-----END \(label)-----\n"
    }

    /// Every DER block in a PEM string, in order — a CA bundle is several
    /// certificates concatenated. Unknown labels are included (the caller
    /// knows what it fetched); garbage between blocks is ignored.
    public static func decodeAll(_ pem: String) -> [Data] {
        var blocks: [Data] = []
        var base64Lines: [Substring] = []
        var inBlock = false
        for line in pem.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("-----BEGIN ") {
                inBlock = true
                base64Lines = []
            } else if trimmed.hasPrefix("-----END ") {
                if inBlock, let der = Data(base64Encoded: base64Lines.joined()) {
                    blocks.append(der)
                }
                inBlock = false
            } else if inBlock {
                base64Lines.append(Substring(trimmed))
            }
        }
        return blocks
    }

    /// The first DER block, for single-certificate PEMs.
    public static func decodeFirst(_ pem: String) -> Data? {
        decodeAll(pem).first
    }

    /// SHA-256 over a certificate's DER, lowercase hex — the CLIENT.md CA
    /// fingerprint format.
    public static func fingerprint(der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Compares an out-of-band fingerprint (any case, optional colons)
    /// against a certificate's actual fingerprint.
    public static func fingerprintMatches(_ expected: String, der: Data) -> Bool {
        let normalized = expected.lowercased().replacingOccurrences(of: ":", with: "")
        return normalized == fingerprint(der: der)
    }
}
