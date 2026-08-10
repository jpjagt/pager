import Foundation

/// `GET /v1/transmissions/{txn}/status` (§5.2). `nextSeq` reflects what the
/// server has durably stored — the resume cursor.
public struct TransmissionStatus: Decodable, Equatable {
    public var state: String
    public var nextSeq: UInt32
    public var durationMs: Int64?

    enum CodingKeys: String, CodingKey {
        case state
        case nextSeq = "next_seq"
        case durationMs = "duration_ms"
    }

    public init(state: String, nextSeq: UInt32, durationMs: Int64? = nil) {
        self.state = state
        self.nextSeq = nextSeq
        self.durationMs = durationMs
    }
}

/// One row of the catch-up fetch: a `tx.start`-shaped record plus `state`
/// and, when complete, duration and frame count (§5.2).
public struct CatchupRecord: Decodable, Equatable {
    public var txnId: String
    public var sender: String
    public var circle: String
    public var txIndex: Int64
    public var frameMs: Int?
    public var state: String
    public var durationMs: Int64?
    public var frameCount: Int?

    enum CodingKeys: String, CodingKey {
        case txnId = "txn_id"
        case sender, circle
        case txIndex = "tx_index"
        case frameMs = "frame_ms"
        case state
        case durationMs = "duration_ms"
        case frameCount = "frame_count"
    }

    public init(txnId: String, sender: String, circle: String, txIndex: Int64,
                frameMs: Int? = nil, state: String, durationMs: Int64? = nil,
                frameCount: Int? = nil) {
        self.txnId = txnId
        self.sender = sender
        self.circle = circle
        self.txIndex = txIndex
        self.frameMs = frameMs
        self.state = state
        self.durationMs = durationMs
        self.frameCount = frameCount
    }
}

public enum VoiceTransportError: Error, Equatable {
    /// `410 Gone` — the transmission was aborted and its audio deleted.
    case gone
    case http(Int)
}

/// The audio plane (§5.2), as the engine sees it. Implementations: the
/// URLSession `RelayClient` below; scripted stubs in tests.
public protocol VoiceTransport: Sendable {
    /// Streams the body of `GET …/stream?from_seq=N` as chunks arrive —
    /// live for an open transmission, from storage for a complete one.
    func download(txnId: String, fromSeq: UInt32) -> AsyncThrowingStream<Data, Error>
    /// `POST …/transmissions/{txn}` with a chunked body fed by `body`;
    /// returns when the server acknowledges the closed body.
    func upload(txnId: String, fromSeq: UInt32?, body: AsyncStream<Data>) async throws
    func status(txnId: String) async throws -> TransmissionStatus
    func catchup(afterIndex: Int64) async throws -> [CatchupRecord]
}
