import Foundation
@testable import VoiceCore

/// Trivial reversible "codec": 2 bytes LE per sample, 4 samples per frame.
/// Keeps engine tests decoupled from libopus behavior.
struct FakeOpusCodec: OpusCodec {
    let samplesPerFrame = 4

    func encode(_ pcm: [Int16]) throws -> Data {
        var data = Data()
        for sample in pcm {
            data.append(UInt8(truncatingIfNeeded: sample))
            data.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return data
    }

    func decode(_ frame: Data) throws -> [Int16] {
        stride(from: 0, to: frame.count - 1, by: 2).map { i in
            Int16(frame[frame.startIndex + i])
                | Int16(frame[frame.startIndex + i + 1]) << 8
        }
    }
}

@MainActor
final class FakeAudioIO: AudioIO {
    private(set) var captureSink: (([Int16]) -> Void)?
    private(set) var playbackNext: (() -> [Int16]?)?
    private(set) var playbackStops = 0
    private(set) var captureStops = 0

    var isCapturing: Bool { captureSink != nil }
    var isPlaying: Bool { playbackNext != nil }

    func startCapture(onFrame: @escaping ([Int16]) -> Void) throws {
        captureSink = onFrame
    }

    func stopCapture() {
        if captureSink != nil { captureStops += 1 }
        captureSink = nil
    }

    func startPlayback(next: @escaping () -> [Int16]?) throws {
        playbackNext = next
    }

    func stopPlayback() {
        if playbackNext != nil { playbackStops += 1 }
        playbackNext = nil
    }

    /// The test's render clock.
    func tick() -> [Int16]? { playbackNext?() }
    func feedMic(_ pcm: [Int16]) { captureSink?(pcm) }
}

@MainActor
final class FakeSignal: SignalChannel {
    var onMessage: ((String, Data) -> Void)?
    var onSessionPresent: ((Bool) -> Void)?
    var onState: ((MqttSession.State) -> Void)?
    private(set) var started = false
    private(set) var published: [Data] = []

    func start() { started = true }
    func stop() { started = false }
    func reconnectNow() {}
    func publish(_ payload: Data) { published.append(payload) }

    func deliver(_ json: String) {
        onMessage?("dl", Data(json.utf8))
    }

    func publishedMessages() -> [[String: Any]] {
        published.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

/// Scripted audio plane. Downloads are either canned bodies (archive) or
/// live continuations the test pushes into (chase). Uploads consume the
/// body, recording every attempt; a scripted plan can sever an attempt
/// after N chunks to exercise the resume flow.
final class FakeVoiceTransport: VoiceTransport, @unchecked Sendable {
    struct UploadAttempt {
        var fromSeq: UInt32?
        var data: Data
        var completed: Bool
    }

    private let lock = NSLock()
    private var cannedDownloads: [String: [Data]] = [:]
    private var liveContinuations: [String: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    private var goneTxns: Set<String> = []
    private var attempts: [UploadAttempt] = []
    /// Attempt indexes (0-based) that should fail after consuming 2 chunks.
    var failUploadAttempts: Set<Int> = []
    var scriptedStatus: TransmissionStatus?
    var scriptedCatchup: [CatchupRecord] = []
    private(set) var catchupCursors: [Int64] = []

    func scriptDownload(txnId: String, chunks: [Data]) {
        lock.lock()
        cannedDownloads[txnId] = chunks
        lock.unlock()
    }

    func scriptGone(txnId: String) {
        lock.lock()
        goneTxns.insert(txnId)
        lock.unlock()
    }

    var uploadAttempts: [UploadAttempt] {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    /// The live end of a chase download, once the engine has connected.
    func liveContinuation(txnId: String) -> AsyncThrowingStream<Data, Error>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        return liveContinuations[txnId]
    }

    func download(txnId: String, fromSeq: UInt32) -> AsyncThrowingStream<Data, Error> {
        // The stream builder runs synchronously inside init — the lock must
        // be released before constructing any stream, or the live branch
        // re-locks it on the same thread.
        lock.lock()
        let gone = goneTxns.contains(txnId)
        let chunks = cannedDownloads[txnId]
        lock.unlock()
        if gone {
            return AsyncThrowingStream { $0.finish(throwing: VoiceTransportError.gone) }
        }
        if let chunks {
            return AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        }
        return AsyncThrowingStream { continuation in
            self.lock.lock()
            self.liveContinuations[txnId] = continuation
            self.lock.unlock()
        }
    }

    func upload(txnId: String, fromSeq: UInt32?, body: AsyncStream<Data>) async throws {
        lock.lock()
        let attemptIndex = attempts.count
        attempts.append(UploadAttempt(fromSeq: fromSeq, data: Data(), completed: false))
        let shouldFail = failUploadAttempts.contains(attemptIndex)
        lock.unlock()

        var consumed = 0
        for await chunk in body {
            lock.lock()
            attempts[attemptIndex].data.append(chunk)
            lock.unlock()
            consumed += 1
            if shouldFail && consumed >= 2 {
                throw VoiceTransportError.http(500)
            }
        }
        lock.lock()
        attempts[attemptIndex].completed = true
        lock.unlock()
    }

    func status(txnId: String) async throws -> TransmissionStatus {
        guard let scriptedStatus else { throw VoiceTransportError.http(404) }
        return scriptedStatus
    }

    func catchup(afterIndex: Int64) async throws -> [CatchupRecord] {
        lock.lock()
        catchupCursors.append(afterIndex)
        defer { lock.unlock() }
        return scriptedCatchup
    }
}

/// Builds a complete VLK1 body from fake-codec frames, for canned downloads.
enum VLKFixtures {
    static func body(frames: [[Int16]], codec: OpusCodec = FakeOpusCodec(),
                     complete: Bool = true) -> Data {
        var data = TxnStreamEncoder.header(StreamHeader())
        for (index, pcm) in frames.enumerated() {
            let payload = (try? codec.encode(pcm)) ?? Data()
            data.append(try! TxnStreamEncoder.frameRecord(seq: UInt32(index),
                                                          payload: payload))
        }
        if complete {
            data.append(TxnStreamEncoder.endOfMessage(seq: UInt32(frames.count)))
        }
        return data
    }
}
