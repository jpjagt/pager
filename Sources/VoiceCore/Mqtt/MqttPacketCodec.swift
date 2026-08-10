import Foundation

/// The MQTT 5 subset the protocol needs (§5.1): CONNECT/CONNACK with the
/// session-present flag, SUBSCRIBE/SUBACK, PUBLISH at QoS 0/1 + PUBACK,
/// ping, DISCONNECT. Everything else decodes to `.unknown` and is dropped by
/// the caller; properties are skipped wholesale by their declared length —
/// the codec-level version of the must-ignore rules.
///
/// Both directions are implemented for every packet so session tests can
/// script a broker byte-for-byte. MQTT integers are big-endian (network
/// order) — unlike the little-endian VLK1 audio stream.

public enum MqttError: Error, Equatable {
    case malformedVarint
    case malformed(String)
}

public enum MqttPacket: Equatable {
    case connect(clientId: String, keepAliveSeconds: UInt16, cleanStart: Bool,
                 sessionExpirySeconds: UInt32)
    case connack(sessionPresent: Bool, reasonCode: UInt8)
    case subscribe(packetId: UInt16, topic: String, qos: UInt8)
    case suback(packetId: UInt16, reasonCodes: [UInt8])
    case publish(topic: String, packetId: UInt16?, payload: Data, qos: UInt8, dup: Bool)
    case puback(packetId: UInt16)
    case pingreq
    case pingresp
    case disconnect(reasonCode: UInt8)
    case unknown(type: UInt8)
}

public enum MqttPacketEncoder {
    public static func encode(_ packet: MqttPacket) -> Data {
        switch packet {
        case .connect(let clientId, let keepAlive, let cleanStart, let sessionExpiry):
            var body = Data()
            body.appendMqttString("MQTT")
            body.append(5) // protocol level
            body.append(cleanStart ? 0x02 : 0x00)
            body.appendBE(keepAlive)
            var properties = Data()
            properties.append(0x11) // session expiry interval
            properties.appendBE(sessionExpiry)
            body.appendVarint(properties.count)
            body.append(properties)
            body.appendMqttString(clientId)
            return fixed(type: 1, flags: 0, body: body)
        case .connack(let sessionPresent, let reasonCode):
            var body = Data([sessionPresent ? 0x01 : 0x00, reasonCode])
            body.appendVarint(0)
            return fixed(type: 2, flags: 0, body: body)
        case .subscribe(let packetId, let topic, let qos):
            var body = Data()
            body.appendBE(packetId)
            body.appendVarint(0)
            body.appendMqttString(topic)
            body.append(qos & 0x03)
            return fixed(type: 8, flags: 0x02, body: body)
        case .suback(let packetId, let reasonCodes):
            var body = Data()
            body.appendBE(packetId)
            body.appendVarint(0)
            body.append(contentsOf: reasonCodes)
            return fixed(type: 9, flags: 0, body: body)
        case .publish(let topic, let packetId, let payload, let qos, let dup):
            var body = Data()
            body.appendMqttString(topic)
            if qos > 0, let packetId { body.appendBE(packetId) }
            body.appendVarint(0)
            body.append(payload)
            let flags = (dup ? 0x08 : 0x00) | UInt8(qos << 1)
            return fixed(type: 3, flags: flags, body: body)
        case .puback(let packetId):
            var body = Data()
            body.appendBE(packetId)
            return fixed(type: 4, flags: 0, body: body)
        case .pingreq:
            return fixed(type: 12, flags: 0, body: Data())
        case .pingresp:
            return fixed(type: 13, flags: 0, body: Data())
        case .disconnect(let reasonCode):
            return fixed(type: 14, flags: 0, body: Data([reasonCode]))
        case .unknown(let type):
            return fixed(type: type, flags: 0, body: Data())
        }
    }

    private static func fixed(type: UInt8, flags: UInt8, body: Data) -> Data {
        var data = Data([type << 4 | flags])
        data.appendVarint(body.count)
        data.append(body)
        return data
    }
}

/// Incremental decoder: feed TCP chunks, get complete packets.
public struct MqttPacketDecoder {
    private var buffer = Data()

    public init() {}

    public mutating func feed(_ chunk: Data) throws -> [MqttPacket] {
        buffer.append(chunk)
        var packets: [MqttPacket] = []
        while let packet = try next() {
            packets.append(packet)
        }
        return packets
    }

    private mutating func next() throws -> MqttPacket? {
        guard buffer.count >= 2 else { return nil }
        let first = buffer[rel: 0]
        var length = 0
        var multiplier = 1
        var index = 1
        while true {
            guard index < buffer.count else { return nil } // varint incomplete
            guard index <= 4 else { throw MqttError.malformedVarint }
            let byte = buffer[rel: index]
            length += Int(byte & 0x7F) * multiplier
            multiplier *= 128
            index += 1
            if byte & 0x80 == 0 { break }
            if index > 4 { throw MqttError.malformedVarint }
        }
        let total = index + length
        guard buffer.count >= total else { return nil }
        let body = Data(buffer[rel: index ..< total])
        buffer.removeFirst(total)
        return try Self.parse(type: first >> 4, flags: first & 0x0F, body: body)
    }

    private static func parse(type: UInt8, flags: UInt8, body: Data) throws -> MqttPacket {
        var reader = ByteReader(body)
        switch type {
        case 1:
            let name = try reader.readString()
            let level = try reader.readU8()
            guard name == "MQTT", level == 5 else { throw MqttError.malformed("connect header") }
            let connectFlags = try reader.readU8()
            let keepAlive = try reader.readU16BE()
            var sessionExpiry: UInt32 = 0
            try reader.readProperties { id, property in
                if id == 0x11 { sessionExpiry = try property.readU32BE() }
            }
            let clientId = try reader.readString()
            return .connect(clientId: clientId, keepAliveSeconds: keepAlive,
                            cleanStart: connectFlags & 0x02 != 0,
                            sessionExpirySeconds: sessionExpiry)
        case 2:
            let ackFlags = try reader.readU8()
            let reason = try reader.readU8()
            try reader.skipPropertiesIfPresent()
            return .connack(sessionPresent: ackFlags & 0x01 != 0, reasonCode: reason)
        case 3:
            let qos = (flags >> 1) & 0x03
            guard qos <= 1 else { throw MqttError.malformed("qos2 unsupported") }
            let topic = try reader.readString()
            let packetId: UInt16? = qos > 0 ? try reader.readU16BE() : nil
            try reader.skipPropertiesIfPresent()
            return .publish(topic: topic, packetId: packetId, payload: reader.rest(),
                            qos: qos, dup: flags & 0x08 != 0)
        case 4:
            let packetId = try reader.readU16BE()
            // Remaining bytes (reason code, properties) may be omitted on
            // success and carry nothing we act on either way.
            return .puback(packetId: packetId)
        case 8:
            let packetId = try reader.readU16BE()
            try reader.skipPropertiesIfPresent()
            let topic = try reader.readString()
            let options = try reader.readU8()
            return .subscribe(packetId: packetId, topic: topic, qos: options & 0x03)
        case 9:
            let packetId = try reader.readU16BE()
            try reader.skipPropertiesIfPresent()
            var codes: [UInt8] = []
            while !reader.isAtEnd { codes.append(try reader.readU8()) }
            return .suback(packetId: packetId, reasonCodes: codes)
        case 12:
            return .pingreq
        case 13:
            return .pingresp
        case 14:
            let reason = reader.isAtEnd ? 0 : try reader.readU8()
            return .disconnect(reasonCode: reason)
        default:
            return .unknown(type: type)
        }
    }
}

/// Sequential big-endian reads over a packet body.
struct ByteReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }

    var isAtEnd: Bool { offset >= data.count }

    mutating func readU8() throws -> UInt8 {
        guard offset < data.count else { throw MqttError.malformed("truncated") }
        defer { offset += 1 }
        return data[rel: offset]
    }

    mutating func readU16BE() throws -> UInt16 {
        UInt16(try readU8()) << 8 | UInt16(try readU8())
    }

    mutating func readU32BE() throws -> UInt32 {
        UInt32(try readU16BE()) << 16 | UInt32(try readU16BE())
    }

    mutating func readVarint() throws -> Int {
        var value = 0
        var multiplier = 1
        for count in 0... {
            guard count < 4 else { throw MqttError.malformedVarint }
            let byte = try readU8()
            value += Int(byte & 0x7F) * multiplier
            multiplier *= 128
            if byte & 0x80 == 0 { break }
        }
        return value
    }

    mutating func readString() throws -> String {
        let length = Int(try readU16BE())
        guard offset + length <= data.count else { throw MqttError.malformed("truncated string") }
        defer { offset += length }
        return String(decoding: data[rel: offset ..< offset + length], as: UTF8.self)
    }

    /// MQTT 5 property block: varint length, then `length` bytes we mostly
    /// skip. Tolerates its absence (a peer omitting the block entirely) —
    /// lenient reading of packets whose tail carries nothing we need.
    mutating func skipPropertiesIfPresent() throws {
        guard !isAtEnd else { return }
        let length = try readVarint()
        guard offset + length <= data.count else { throw MqttError.malformed("truncated properties") }
        offset += length
    }

    /// Reads the property block, handing each (id, value-reader) to `handle`.
    /// Only ids the caller matches are interpreted; everything else is skipped
    /// by re-reading the block — properties have no per-item length, so the
    /// simple safe route is: known ids parse, first unknown id stops the scan.
    mutating func readProperties(_ handle: (UInt8, inout ByteReader) throws -> Void) throws {
        let length = try readVarint()
        guard offset + length <= data.count else { throw MqttError.malformed("truncated properties") }
        var block = ByteReader(Data(data[rel: offset ..< offset + length]))
        offset += length
        while !block.isAtEnd {
            let id = try block.readU8()
            switch id {
            case 0x11: try handle(id, &block) // session expiry (u32)
            default: return // unknown property: stop interpreting, block already skipped
            }
        }
    }

    mutating func rest() -> Data {
        defer { offset = data.count }
        return Data(data[rel: offset...])
    }
}

extension Data {
    subscript(rel range: PartialRangeFrom<Int>) -> Data {
        self[(startIndex + range.lowerBound)...]
    }

    mutating func appendBE(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBE(_ value: UInt32) {
        appendBE(UInt16(value >> 16))
        appendBE(UInt16(value & 0xFFFF))
    }

    mutating func appendVarint(_ value: Int) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining % 128)
            remaining /= 128
            if remaining > 0 { byte |= 0x80 }
            append(byte)
        } while remaining > 0
    }

    mutating func appendMqttString(_ string: String) {
        let bytes = Data(string.utf8)
        appendBE(UInt16(bytes.count))
        append(bytes)
    }
}
