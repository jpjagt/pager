import Foundation

/// The §7 JSON control messages. Decoding obeys the protocol's evolution
/// rules: unrecognized message types decode to `.unknown` (callers drop them),
/// and unknown keys inside recognized types are ignored by Codable's default
/// behavior — except receipt patches, whose unknown keys are preserved.

public struct TxStart: Codable, Equatable {
    public var txnId: String
    public var sender: String
    public var circle: String
    public var txIndex: Int64
    public var codec: String?
    public var sampleRate: Int?
    public var frameMs: Int?
    public var ts: Int64?

    enum CodingKeys: String, CodingKey {
        case txnId = "txn_id"
        case sender, circle
        case txIndex = "tx_index"
        case codec
        case sampleRate = "sample_rate"
        case frameMs = "frame_ms"
        case ts
    }

    public init(txnId: String, sender: String, circle: String, txIndex: Int64,
                codec: String? = "opus", sampleRate: Int? = VoiceConfig.sampleRate,
                frameMs: Int? = VoiceConfig.frameMs, ts: Int64? = nil) {
        self.txnId = txnId
        self.sender = sender
        self.circle = circle
        self.txIndex = txIndex
        self.codec = codec
        self.sampleRate = sampleRate
        self.frameMs = frameMs
        self.ts = ts
    }
}

public struct TxEnd: Codable, Equatable {
    public var txnId: String
    public var durationMs: Int64?
    public var frameCount: Int?

    enum CodingKeys: String, CodingKey {
        case txnId = "txn_id"
        case durationMs = "duration_ms"
        case frameCount = "frame_count"
    }

    public init(txnId: String, durationMs: Int64? = nil, frameCount: Int? = nil) {
        self.txnId = txnId
        self.durationMs = durationMs
        self.frameCount = frameCount
    }
}

public struct TxAbort: Codable, Equatable {
    public var txnId: String
    public var reason: String?

    enum CodingKeys: String, CodingKey {
        case txnId = "txn_id"
        case reason
    }

    public init(txnId: String, reason: String? = nil) {
        self.txnId = txnId
        self.reason = reason
    }
}

/// Both directions of §7.2. Outbound (device → `up`) has no `device_id`;
/// the server's echo to circle members annotates whose receipt changed.
public struct ReceiptPatch: Codable, Equatable {
    public var txnId: String
    public var deviceId: String?
    public var patch: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case txnId = "txn_id"
        case deviceId = "device_id"
        case patch
    }

    public init(txnId: String, deviceId: String? = nil, patch: [String: JSONValue]) {
        self.txnId = txnId
        self.deviceId = deviceId
        self.patch = patch
    }
}

/// §7.3, outbound best-effort after a playback.
public struct ClientStats: Codable, Equatable {
    public var txnId: String
    public var underruns: Int
    public var minBufferMs: Int
    public var startBufferMs: Int

    enum CodingKeys: String, CodingKey {
        case txnId = "txn_id"
        case underruns
        case minBufferMs = "min_buffer_ms"
        case startBufferMs = "start_buffer_ms"
    }

    public init(txnId: String, underruns: Int, minBufferMs: Int, startBufferMs: Int) {
        self.txnId = txnId
        self.underruns = underruns
        self.minBufferMs = minBufferMs
        self.startBufferMs = startBufferMs
    }
}

public enum ControlMessage: Equatable {
    case txStart(TxStart)
    case txEnd(TxEnd)
    case txAbort(TxAbort)
    case receiptPatch(ReceiptPatch)
    /// A type (or major version) this client does not understand. Kept as a
    /// case rather than an error so callers can log-and-ignore, per §7.
    case unknown(type: String)
}

public enum ControlWire {
    /// The protocol's receipt keys and their scopes (§7.2): `delivered_at` is
    /// a fact about one device's flash; `heard_at`/`saved` belong to the user
    /// across all their clients.
    public enum ReceiptScope { case device, user }

    public static func receiptScope(of key: String) -> ReceiptScope? {
        switch key {
        case "delivered_at": return .device
        case "heard_at", "saved": return .user
        default: return nil
        }
    }

    private struct Probe: Decodable {
        let v: Int?
        let type: String?
    }

    /// Decodes one inbound `dl` message. Throws only on malformed JSON or a
    /// missing `type`; anything merely unfamiliar becomes `.unknown`. A
    /// missing `v` defaults to 1 — the published schemas don't require it.
    public static func decode(_ data: Data) throws -> ControlMessage {
        let decoder = JSONDecoder()
        let probe = try decoder.decode(Probe.self, from: data)
        guard let type = probe.type else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "missing type"))
        }
        guard (probe.v ?? VoiceConfig.protocolVersion) == VoiceConfig.protocolVersion else {
            return .unknown(type: type)
        }
        switch type {
        case "tx.start": return .txStart(try decoder.decode(TxStart.self, from: data))
        case "tx.end": return .txEnd(try decoder.decode(TxEnd.self, from: data))
        case "tx.abort": return .txAbort(try decoder.decode(TxAbort.self, from: data))
        case "receipt.patch": return .receiptPatch(try decoder.decode(ReceiptPatch.self, from: data))
        default: return .unknown(type: type)
        }
    }

    /// Encodes one outbound `up` message, injecting the `v`/`type` envelope.
    public static func encode(_ patch: ReceiptPatch) throws -> Data {
        try encodeEnvelope(type: "receipt.patch", payload: patch)
    }

    public static func encode(_ stats: ClientStats) throws -> Data {
        try encodeEnvelope(type: "client.stats", payload: stats)
    }

    private static func encodeEnvelope<T: Encodable>(type: String, payload: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var object = try JSONSerialization.jsonObject(
            with: encoder.encode(payload)) as? [String: Any] ?? [:]
        object["v"] = VoiceConfig.protocolVersion
        object["type"] = type
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
