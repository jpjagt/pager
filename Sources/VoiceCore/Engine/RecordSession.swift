import Foundation
import PagerCore

/// One outgoing transmission: PCM frames in, a chunked upload out, with the
/// §5.2 resume flow on any drop. Frames stay buffered (encoded — a minute
/// of speech is ~360 KB) until the server has acknowledged the closed body,
/// so a resume can always re-send from whatever `next_seq` the server
/// reports.
///
/// Capture starts before the connection is ready by design: the upload pump
/// simply drains the buffer when the transport lets it (the pendant's
/// "connection setup hidden inside the recording", spec §1.4).
@MainActor
public final class RecordSession {
    public enum State: Equatable {
        case recording
        case uploading // button released, EOM queued, upload not yet acked
        case done
        case discarded
    }

    public let txnId: String
    public private(set) var state: State = .recording

    private let transport: VoiceTransport
    private let codec: OpusCodec
    private let header: StreamHeader
    private let log: SyncLogSink
    private var frames: [Data] = []
    private var stopped = false
    private var uploadTask: Task<Void, Never>?
    private var backoff = Backoff()

    /// Mints the transmission id the §4 way: 128 random bits, no server
    /// round-trip.
    public nonisolated static func mintTxnId() -> String {
        (0 ..< 16).map { _ in String(format: "%02x", UInt8.random(in: 0 ... 255)) }.joined()
    }

    public init(transport: VoiceTransport, codec: OpusCodec,
                txnId: String = RecordSession.mintTxnId(),
                header: StreamHeader = StreamHeader(),
                log: SyncLogSink = NoopSyncLog()) {
        self.transport = transport
        self.codec = codec
        self.txnId = txnId
        self.header = header
        self.log = log
    }

    public var frameCount: Int { frames.count }
    public var durationMs: Int { frames.count * Int(header.frameMs) }

    private func event(_ ev: String, error: String? = nil) {
        log.log(SyncLogEvent(ev: ev, link: String(txnId.prefix(8)),
                             len: frames.count, error: error))
    }

    /// Kicks off the upload pump. Call once, before or after the first frame.
    public func start() {
        event("rec.start")
        uploadTask = Task { await runUpload() }
    }

    /// One PCM frame from the mic (already frame-sized by `AudioIO`).
    public func append(pcm: [Int16]) {
        guard state == .recording else { return }
        guard let encoded = try? codec.encode(pcm) else { return }
        frames.append(encoded)
    }

    /// Button up: closes the stream with the end-of-message record and
    /// returns once the server has the complete transmission (or the task
    /// is cancelled). Callers that can't wait use `finish()`.
    public func stop() async {
        guard state == .recording else { return }
        state = .uploading
        stopped = true
        event("rec.stop")
        await uploadTask?.value
        if state == .uploading { state = .done }
        event("rec.done")
    }

    /// Fire-and-forget `stop()` for callers that only need the state change.
    public func finish() {
        Task { await stop() }
    }

    /// The ✕ path: no end-of-message is ever sent, the upload stops, and the
    /// server's resume window expires into a `tx.abort` (§7.1) — deletion by
    /// silence, which is the only deletion the protocol has.
    public func discard() {
        state = .discarded
        stopped = true
        uploadTask?.cancel()
        uploadTask = nil
        frames.removeAll()
        event("rec.discard")
    }

    /// App-termination flush, the `SyncEngine.flushSynchronously` pattern:
    /// quitting commits — the recording ends and the upload gets `timeout`
    /// seconds to land before the process dies.
    ///
    /// The normal upload pump lives on the main actor, and this call *blocks*
    /// the main thread — awaiting the pump here would deadlock (the same trap
    /// `SyncEngine.flushSynchronously` documents). So the pump is cancelled
    /// and replaced by one detached re-POST of the complete body from seq 0:
    /// legal because stream readers discard already-seen sequence numbers
    /// (§6), so a full overlap converges server-side.
    public func flushSynchronously(timeout: TimeInterval = 3) {
        guard state == .recording || state == .uploading else { return }
        state = .uploading
        stopped = true
        uploadTask?.cancel()
        uploadTask = nil
        event("rec.flush_sync")

        var blob = TxnStreamEncoder.header(header)
        for (index, frame) in frames.enumerated() {
            if let record = try? TxnStreamEncoder.frameRecord(seq: UInt32(index),
                                                              payload: frame) {
                blob.append(record)
            }
        }
        blob.append(TxnStreamEncoder.endOfMessage(seq: UInt32(frames.count)))

        let transport = self.transport
        let txnId = self.txnId
        let body = blob
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let stream = AsyncStream<Data> { continuation in
                continuation.yield(body)
                continuation.finish()
            }
            try? await transport.upload(txnId: txnId, fromSeq: nil, body: stream)
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        state = .done
    }

    // MARK: - Upload pump

    private func runUpload() async {
        var fromSeq: UInt32 = 0
        var restatedHeader = false
        while !Task.isCancelled {
            do {
                try await transport.upload(txnId: txnId,
                                           fromSeq: restatedHeader ? fromSeq : nil,
                                           body: makeBody(fromSeq: fromSeq))
                return // server acked the closed body
            } catch is CancellationError {
                return
            } catch {
                event("rec.upload_drop", error: "\(error)")
            }
            guard !Task.isCancelled else { return }
            let delay = backoff.nextDelay()
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Resume: ask what the server durably has, restart there.
            if let status = try? await transport.status(txnId: txnId) {
                fromSeq = status.nextSeq
            }
            restatedHeader = true
        }
    }

    /// The chunked body: header, then frame records pumped as they exist,
    /// then EOM once the button is up and everything is out. The 10 ms poll
    /// is against a 60 ms frame cadence — cheap, and it keeps the pump free
    /// of cross-task signalling.
    private func makeBody(fromSeq: UInt32) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self else { return continuation.finish() }
                continuation.yield(TxnStreamEncoder.header(self.header))
                var cursor = Int(fromSeq)
                while true {
                    if Task.isCancelled || self.state == .discarded {
                        return continuation.finish()
                    }
                    if cursor < self.frames.count {
                        if let record = try? TxnStreamEncoder.frameRecord(
                            seq: UInt32(cursor), payload: self.frames[cursor]) {
                            continuation.yield(record)
                        }
                        cursor += 1
                    } else if self.stopped {
                        continuation.yield(TxnStreamEncoder.endOfMessage(
                            seq: UInt32(self.frames.count)))
                        return continuation.finish()
                    } else {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
