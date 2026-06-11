import Foundation
import CryptoKit

/// 16 Crockford-base32 chars: 14 random (70 bits) + 2 checksum chars.
/// The code never leaves the device; it is both DB address and encryption key.
public struct ShareCode: Equatable, Hashable {
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// The 14 entropy characters (uppercase Crockford base32).
    public let entropy: String

    public init(entropy: String) {
        precondition(entropy.count == 14)
        self.entropy = entropy
    }

    /// 16-char canonical form: entropy + checksum.
    public var full: String { entropy + Self.checksum(for: entropy) }

    /// Display form: ABCD-EFGH-JKLM-NPQR
    public var display: String {
        let chars = Array(full)
        return stride(from: 0, to: 16, by: 4)
            .map { String(chars[$0..<$0 + 4]) }
            .joined(separator: "-")
    }

    public static func generate() -> ShareCode {
        // SystemRandomNumberGenerator is cryptographically secure on Apple platforms.
        var rng = SystemRandomNumberGenerator()
        let chars = (0..<14).map { _ in alphabet.randomElement(using: &rng)! }
        return ShareCode(entropy: String(chars))
    }

    /// Leading 10 bits of SHA-256 of the entropy string, as two base32 chars.
    static func checksum(for entropy: String) -> String {
        let digest = Array(SHA256.hash(data: Data(entropy.utf8)))
        let tenBits = (Int(digest[0]) << 2) | (Int(digest[1]) >> 6)
        return String([alphabet[tenBits >> 5], alphabet[tenBits & 0x1F]])
    }

    public static func parse(_ input: String) -> ShareCode? {
        let normalized = input.uppercased()
            .filter { $0 != "-" && $0 != " " }
            .map { (c: Character) -> Character in
                switch c {
                case "O": return "0"
                case "I", "L": return "1"
                default: return c
                }
            }
        guard normalized.count == 16,
              normalized.allSatisfy({ alphabet.contains($0) }) else { return nil }
        let entropy = String(normalized.prefix(14))
        guard String(normalized.suffix(2)) == checksum(for: entropy) else { return nil }
        return ShareCode(entropy: entropy)
    }
}
