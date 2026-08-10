import Foundation

/// The half-dozen DER constructions a PKCS#10 CSR needs — nothing more.
/// Encode-only: the client never parses DER (certificates go straight into
/// the Keychain, which does its own parsing).
enum DER {
    static func sequence(_ children: [Data]) -> Data {
        tagged(0x30, children.reduce(Data(), +))
    }

    static func set(_ children: [Data]) -> Data {
        tagged(0x31, children.reduce(Data(), +))
    }

    /// Context-specific constructed tag, e.g. `[0]` for CSR attributes.
    static func contextConstructed(_ number: UInt8, _ content: Data) -> Data {
        tagged(0xA0 | number, content)
    }

    static func integer(_ value: Int) -> Data {
        precondition(value >= 0 && value < 128, "only small non-negative integers needed")
        return tagged(0x02, Data([UInt8(value)]))
    }

    static func utf8String(_ string: String) -> Data {
        tagged(0x0C, Data(string.utf8))
    }

    /// Assumes whole bytes (unused-bits count 0) — true for both public keys
    /// and signatures here.
    static func bitString(_ bytes: Data) -> Data {
        tagged(0x03, Data([0x00]) + bytes)
    }

    static func objectIdentifier(_ arcs: [UInt64]) -> Data {
        precondition(arcs.count >= 2)
        var content = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for arc in arcs.dropFirst(2) {
            content.append(base128(arc))
        }
        return tagged(0x06, content)
    }

    private static func base128(_ value: UInt64) -> Data {
        var groups: [UInt8] = [UInt8(value & 0x7F)]
        var remaining = value >> 7
        while remaining > 0 {
            groups.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        return Data(groups.reversed())
    }

    private static func tagged(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag]) + length(content.count) + content
    }

    static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}
