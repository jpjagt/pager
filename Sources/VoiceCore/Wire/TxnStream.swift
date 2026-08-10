import Foundation

/// The §6 binary audio stream format: one 8-byte header, then frame records,
/// closed by an end-of-message record (`len == 0`). All integers little-endian.

public struct StreamHeader: Equatable {
    /// "VLK1" read as a little-endian u32.
    public static let magic: UInt32 = 0x314B_4C56

    public var version: UInt8
    public var codec: UInt8
    public var frameMs: UInt8
    public var channels: UInt8

    public static let opusCodec: UInt8 = 1

    public init(version: UInt8 = 1, codec: UInt8 = StreamHeader.opusCodec,
                frameMs: UInt8 = UInt8(VoiceConfig.frameMs), channels: UInt8 = 1) {
        self.version = version
        self.codec = codec
        self.frameMs = frameMs
        self.channels = channels
    }
}

public enum TxnStreamError: Error, Equatable {
    case badMagic
    case unsupportedVersion(UInt8)
    case payloadTooLong(Int)
    case sequenceGap(expected: UInt32, got: UInt32)
    case dataAfterEnd
}

/// Encodes upload bodies. Stateless — the caller owns `seq` numbering, which
/// is what makes the resume flow (`from_seq = next_seq`) trivial to express.
public enum TxnStreamEncoder {
    /// Opus payloads are 1–1275 bytes (§6); 0 is reserved for end-of-message.
    public static let maxPayloadLength = 1275

    public static func header(_ h: StreamHeader) -> Data {
        var data = Data(capacity: 8)
        data.appendLE(StreamHeader.magic)
        data.append(contentsOf: [h.version, h.codec, h.frameMs, h.channels])
        return data
    }

    public static func frameRecord(seq: UInt32, payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maxPayloadLength else {
            throw TxnStreamError.payloadTooLong(payload.count)
        }
        var data = Data(capacity: 6 + payload.count)
        data.appendLE(seq)
        data.appendLE(UInt16(payload.count))
        data.append(payload)
        return data
    }

    public static func endOfMessage(seq: UInt32) -> Data {
        var data = Data(capacity: 6)
        data.appendLE(seq)
        data.appendLE(UInt16(0))
        return data
    }
}

/// Incremental decoder for download bodies (and resumed-upload validation).
/// Feed it chunks as they arrive; it emits complete events and buffers the
/// rest. Records with `seq` below the next expected are silently discarded —
/// the §6 rule that a sloppy resume overlap must never double-play a frame.
public struct TxnStreamDecoder {
    public enum Event: Equatable {
        case header(StreamHeader)
        case frame(seq: UInt32, payload: Data)
        case end(seq: UInt32)
    }

    private enum Phase {
        case awaitingHeader
        case awaitingRecords
        case complete
    }

    private var buffer = Data()
    private var phase: Phase = .awaitingHeader
    private var nextSeq: UInt32

    /// `firstSeq` — for a `?from_seq=N` download, the first frame the caller
    /// expects; earlier records are overlap and get discarded.
    public init(firstSeq: UInt32 = 0) {
        nextSeq = firstSeq
    }

    public private(set) var isComplete = false

    public mutating func feed(_ chunk: Data) throws -> [Event] {
        guard !(phase == .complete && !chunk.isEmpty) else {
            throw TxnStreamError.dataAfterEnd
        }
        buffer.append(chunk)
        var events: [Event] = []
        while let event = try next() {
            events.append(event)
        }
        return events
    }

    private mutating func next() throws -> Event? {
        switch phase {
        case .complete:
            if !buffer.isEmpty { throw TxnStreamError.dataAfterEnd }
            return nil
        case .awaitingHeader:
            guard buffer.count >= 8 else { return nil }
            let magic: UInt32 = buffer.readLE(at: 0)
            guard magic == StreamHeader.magic else { throw TxnStreamError.badMagic }
            let header = StreamHeader(version: buffer[rel: 4], codec: buffer[rel: 5],
                                      frameMs: buffer[rel: 6], channels: buffer[rel: 7])
            guard header.version == 1 else {
                throw TxnStreamError.unsupportedVersion(header.version)
            }
            buffer.removeFirst(8)
            phase = .awaitingRecords
            return .header(header)
        case .awaitingRecords:
            guard buffer.count >= 6 else { return nil }
            let seq: UInt32 = buffer.readLE(at: 0)
            let len: UInt16 = buffer.readLE(at: 4)
            guard Int(len) <= TxnStreamEncoder.maxPayloadLength else {
                throw TxnStreamError.payloadTooLong(Int(len))
            }
            guard buffer.count >= 6 + Int(len) else { return nil }
            let payload = Data(buffer[rel: 6 ..< 6 + Int(len)])
            buffer.removeFirst(6 + Int(len))
            if len == 0 {
                phase = .complete
                isComplete = true
                if !buffer.isEmpty { throw TxnStreamError.dataAfterEnd }
                return .end(seq: seq)
            }
            if seq < nextSeq { return try next() } // overlap from a sloppy resume: skip
            guard seq == nextSeq else {
                throw TxnStreamError.sequenceGap(expected: nextSeq, got: seq)
            }
            nextSeq = seq + 1
            return .frame(seq: seq, payload: payload)
        }
    }
}

extension Data {
    /// Subscript relative to startIndex — Data slices keep parent indices, so
    /// absolute subscripts are a classic trap.
    subscript(rel offset: Int) -> UInt8 { self[startIndex + offset] }
    subscript(rel range: Range<Int>) -> Data {
        self[(startIndex + range.lowerBound) ..< (startIndex + range.upperBound)]
    }

    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func readLE(at offset: Int) -> UInt32 {
        UInt32(self[rel: offset]) | UInt32(self[rel: offset + 1]) << 8
            | UInt32(self[rel: offset + 2]) << 16 | UInt32(self[rel: offset + 3]) << 24
    }

    func readLE(at offset: Int) -> UInt16 {
        UInt16(self[rel: offset]) | UInt16(self[rel: offset + 1]) << 8
    }
}
