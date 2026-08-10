import Foundation
import PagerCore

/// What `MqttSession` provides, as a seam so engine tests can script the
/// broker without bytes.
@MainActor
public protocol SignalChannel: AnyObject {
    var onMessage: ((String, Data) -> Void)? { get set }
    var onSessionPresent: ((Bool) -> Void)? { get set }
    var onState: ((MqttSession.State) -> Void)? { get set }
    func start()
    func stop()
    func reconnectNow()
    func publish(_ payload: Data)
}

extension MqttSession: SignalChannel {}

/// One per circle (the per-link invariant, carried over). Owns everything
/// between the wire and the LED: the transmission table and unheard queue
/// (ordered by `tx_index`, never by clock), receipts in both scopes,
/// downloads, playback through `PlayoutMachine`, recording through
/// `RecordSession`, and the §1.1 verbs (tap = play/stop, hold = record).
/// The status item renders exactly what `onLed` says and nothing more.
@MainActor
public final class VoiceEngine {
    /// The menu bar LED, in priority order.
    public enum Led: Equatable {
        case recording
        case uploading
        case playing
        case incoming // a live transmission is open — chase-play available
        case unheard(Int)
        case offline
        case idle
    }

    public var onLed: ((Led) -> Void)?

    public let circleId: UUID
    private let config: CircleConfig
    private let signal: SignalChannel
    private let transport: VoiceTransport
    private let codec: OpusCodec
    private let audio: AudioIO
    private let messages: MessageStore
    private let circles: CircleStore
    private let log: SyncLogSink
    /// Epoch seconds for receipt timestamps — informational only (§7.2).
    private let now: () -> Int64

    private var signalState: MqttSession.State = .offline
    /// Live transmissions from other members: txnId → sender device.
    private var openTransmissions: [String: String] = [:]
    private var record: RecordSession?
    private var playback: Playback?
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var lastLed: Led?

    private struct Playback {
        var txnId: String
        var machine: PlayoutMachine
        var frameMs: Int
        /// Encoded separator frames still to render before the next message.
        var separator: [Data] = []
    }

    public init(circleId: UUID, config: CircleConfig, signal: SignalChannel,
                transport: VoiceTransport, codec: OpusCodec, audio: AudioIO,
                messages: MessageStore, circles: CircleStore,
                log: SyncLogSink = NoopSyncLog(),
                now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.circleId = circleId
        self.config = config
        self.signal = signal
        self.transport = transport
        self.codec = codec
        self.audio = audio
        self.messages = messages
        self.circles = circles
        self.log = log
        self.now = now
    }

    private func event(_ ev: String, error: String? = nil, state: String? = nil) {
        log.log(SyncLogEvent(ev: ev, link: config.circleId, state: state, error: error))
    }

    // MARK: - Lifecycle

    public func start() {
        signal.onMessage = { [weak self] _, payload in self?.handleSignal(payload) }
        signal.onSessionPresent = { [weak self] present in
            guard let self else { return }
            // An absent broker session means queued events were lost — the
            // catch-up fetch is the source of truth for what we missed (§5.1).
            if !present { Task { await self.catchUp() } }
        }
        signal.onState = { [weak self] state in
            self?.signalState = state
            self?.recomputeLed()
        }
        signal.start()
        recomputeLed()
    }

    public func stop() {
        signal.stop()
        audio.stopCapture()
        audio.stopPlayback()
        downloadTasks.values.forEach { $0.cancel() }
        downloadTasks = [:]
        playback = nil
        record?.discard()
        record = nil
    }

    /// Network path restored / wake from sleep.
    public func reconnectNow() {
        signal.reconnectNow()
    }

    /// Quit path: quitting commits — an in-flight recording ends and its
    /// upload gets a moment to land (never discards, matching the pagers).
    public func flushSynchronously(timeout: TimeInterval = 3) {
        audio.stopCapture()
        record?.flushSynchronously(timeout: timeout)
    }

    // MARK: - The verbs (§1.1, keyboard edition)

    /// Tap: play the unheard queue oldest-first; tap during playback stops.
    public func playTapped() {
        guard record == nil else { return } // recording owns the audio path
        if playback != nil {
            stopPlayback()
            return
        }
        playNextInQueue(startingFresh: true)
    }

    /// Hold began: start recording. Stops playback first — the speaker never
    /// sounds while the mic is live (pendant invariant #1).
    public func recordPressed() {
        guard record == nil else { return }
        stopPlayback()
        let session = RecordSession(transport: transport, codec: codec, log: log)
        record = session
        session.start()
        do {
            try audio.startCapture { [weak session] pcm in
                session?.append(pcm: pcm)
            }
        } catch {
            event("rec.capture_fail", error: "\(error)")
            session.discard()
            record = nil
        }
        recomputeLed()
    }

    /// Hold ended: stop capture, close the stream, wait out the upload.
    public func recordReleased() {
        guard let session = record else { return }
        audio.stopCapture()
        recomputeLed() // uploading
        Task {
            await session.stop()
            if self.record === session { self.record = nil }
            self.recomputeLed()
        }
    }

    /// Menu-only cancel: stop without an end-of-message; the server's
    /// resume window expires into `tx.abort` and deletes the partial (§7.1).
    public func recordDiscarded() {
        guard let session = record else { return }
        audio.stopCapture()
        session.discard()
        record = nil
        recomputeLed()
    }

    public var isRecording: Bool { record?.state == .recording }
    public var recordingDurationMs: Int { record?.durationMs ?? 0 }
    public var unheardCount: Int {
        messages.index(circleId: circleId).filter { !$0.heard }.count
    }

    // MARK: - Inbound signalling

    private func handleSignal(_ payload: Data) {
        guard let message = try? ControlWire.decode(payload) else {
            event("sig.malformed")
            return
        }
        switch message {
        case .txStart(let start):
            handleTxStart(start)
        case .txEnd(let end):
            handleTxEnd(end)
        case .txAbort(let abort):
            handleTxAbort(abort)
        case .receiptPatch(let patch):
            handleReceipt(patch)
        case .unknown(let type):
            event("sig.ignored", state: type)
        }
    }

    private func handleTxStart(_ start: TxStart) {
        circles.advanceTxIndex(id: circleId, to: start.txIndex)
        guard start.sender != config.deviceId else { return } // our own echo
        let existing = messages.message(circleId: circleId, txnId: start.txnId)
        guard existing == nil else { return } // QoS 1 duplicate
        messages.upsert(circleId: circleId, StoredMessage(
            txnId: start.txnId, txIndex: start.txIndex, sender: start.sender,
            frameMs: start.frameMs ?? VoiceConfig.frameMs))
        openTransmissions[start.txnId] = start.sender
        event("tx.start", state: start.txnId)
        recomputeLed()
    }

    private func handleTxEnd(_ end: TxEnd) {
        openTransmissions[end.txnId] = nil
        guard var stored = messages.message(circleId: circleId, txnId: end.txnId) else {
            return // not ours (own transmission) or already gone
        }
        stored.durationMs = end.durationMs
        messages.upsert(circleId: circleId, stored)
        if !messages.hasAudio(circleId: circleId, txnId: end.txnId) {
            eagerDownload(txnId: end.txnId)
        }
        recomputeLed()
    }

    private func handleTxAbort(_ abort: TxAbort) {
        openTransmissions[abort.txnId] = nil
        downloadTasks[abort.txnId]?.cancel()
        downloadTasks[abort.txnId] = nil
        messages.remove(circleId: circleId, txnId: abort.txnId)
        if playback?.txnId == abort.txnId { stopPlayback() }
        event("tx.abort", state: abort.txnId)
        recomputeLed()
    }

    /// §7.2 receipt scopes. Patches from this device are echoes of what we
    /// already applied. Patches from the user's *other* clients carry the
    /// user-scoped keys: heard elsewhere is heard here — the unheard queue
    /// (and LED) must drop the message.
    private func handleReceipt(_ patch: ReceiptPatch) {
        guard let device = patch.deviceId, device != config.deviceId else { return }
        guard config.userId(forDevice: device) == config.userId else {
            return // another member's receipt; nothing to show in v1
        }
        guard var stored = messages.message(circleId: circleId, txnId: patch.txnId) else { return }
        for (key, value) in patch.patch where ControlWire.receiptScope(of: key) == .user {
            switch key {
            case "heard_at":
                stored.heard = !value.isNull
            case "saved":
                stored.saved = value.boolValue ?? false
            default:
                break
            }
        }
        messages.upsert(circleId: circleId, stored)
        event("receipt.folded", state: patch.txnId)
        recomputeLed()
    }

    // MARK: - Catch-up (§5.2)

    private func catchUp() async {
        let cursor = circles.circles.first { $0.id == circleId }?.lastTxIndex ?? 0
        guard let records = try? await transport.catchup(afterIndex: cursor) else {
            event("catchup.fail")
            return
        }
        event("catchup", state: "\(records.count)")
        for record in records {
            circles.advanceTxIndex(id: circleId, to: record.txIndex)
            guard record.sender != config.deviceId else { continue }
            switch record.state {
            case "aborted":
                continue // kept its index; audio is gone
            case "open":
                if messages.message(circleId: circleId, txnId: record.txnId) == nil {
                    messages.upsert(circleId: circleId, StoredMessage(
                        txnId: record.txnId, txIndex: record.txIndex,
                        sender: record.sender,
                        frameMs: record.frameMs ?? VoiceConfig.frameMs))
                }
                openTransmissions[record.txnId] = record.sender
            default: // complete
                var stored = messages.message(circleId: circleId, txnId: record.txnId)
                    ?? StoredMessage(txnId: record.txnId, txIndex: record.txIndex,
                                     sender: record.sender,
                                     frameMs: record.frameMs ?? VoiceConfig.frameMs)
                stored.durationMs = record.durationMs
                messages.upsert(circleId: circleId, stored)
                if !stored.heard, !messages.hasAudio(circleId: circleId, txnId: record.txnId) {
                    eagerDownload(txnId: record.txnId)
                }
            }
        }
        recomputeLed()
    }

    // MARK: - Downloads

    /// Pulls a complete transmission to disk, then emits the delivered
    /// receipt — `delivered_at` states "in local flash", so it fires only
    /// after the write (§7.2).
    private func eagerDownload(txnId: String) {
        guard downloadTasks[txnId] == nil else { return }
        downloadTasks[txnId] = Task { [weak self] in
            guard let self else { return }
            defer { self.downloadTasks[txnId] = nil }
            var raw = Data()
            do {
                for try await chunk in self.transport.download(txnId: txnId, fromSeq: 0) {
                    raw.append(chunk)
                }
                self.messages.writeAudio(circleId: self.circleId, txnId: txnId, bytes: raw)
                self.publishReceipt(txnId: txnId, patch: ["delivered_at": .int(self.now())])
                self.event("dl.stored", state: txnId)
            } catch VoiceTransportError.gone {
                self.messages.remove(circleId: self.circleId, txnId: txnId)
            } catch {
                self.event("dl.fail", error: "\(error)") // retried on next tx.end/catch-up
            }
            self.recomputeLed()
        }
    }

    // MARK: - Playback

    private func playNextInQueue(startingFresh: Bool) {
        let queue = messages.index(circleId: circleId)
        let unheard = queue.filter { !$0.heard }
        // Unheard plays oldest-first; with nothing unheard, a fresh tap
        // replays the most recent message (history stays reachable, §1.4).
        guard let next = unheard.first ?? (startingFresh ? queue.last : nil) else {
            stopPlayback()
            return
        }
        var machine = PlayoutMachine(frameMs: next.frameMs)
        var isLive = false
        if let raw = messages.readAudio(circleId: circleId, txnId: next.txnId) {
            var decoder = TxnStreamDecoder()
            for eventItem in (try? decoder.feed(raw)) ?? [] {
                switch eventItem {
                case .frame(_, let payload): machine.receive(payload)
                case .end: machine.endOfMessage()
                case .header: break
                }
            }
        } else {
            isLive = true // open or still downloading: chase the stream
        }
        machine.begin()

        let starting = playback == nil
        let separator = playback?.separator ?? []
        playback = Playback(txnId: next.txnId, machine: machine,
                            frameMs: next.frameMs, separator: separator)
        if isLive { chaseDownload(txnId: next.txnId) }
        if starting {
            do {
                try audio.startPlayback { [weak self] in self?.renderTick() }
            } catch {
                event("play.fail", error: "\(error)")
                playback = nil
            }
        }
        event("play.begin", state: next.txnId)
        recomputeLed()
    }

    /// Live (chase) download: frames go straight into the machine as they
    /// arrive; the raw bytes are kept and stored on completion like any
    /// other download.
    private func chaseDownload(txnId: String) {
        downloadTasks[txnId]?.cancel() // replace any eager download
        downloadTasks[txnId] = Task { [weak self] in
            guard let self else { return }
            defer { self.downloadTasks[txnId] = nil }
            var raw = Data()
            var decoder = TxnStreamDecoder()
            do {
                for try await chunk in self.transport.download(txnId: txnId, fromSeq: 0) {
                    raw.append(chunk)
                    for eventItem in try decoder.feed(chunk) {
                        guard self.playback?.txnId == txnId else { break }
                        switch eventItem {
                        case .frame(_, let payload): self.playback?.machine.receive(payload)
                        case .end: self.playback?.machine.endOfMessage()
                        case .header: break
                        }
                    }
                }
                if decoder.isComplete {
                    self.messages.writeAudio(circleId: self.circleId, txnId: txnId, bytes: raw)
                    self.publishReceipt(txnId: txnId,
                                        patch: ["delivered_at": .int(self.now())])
                }
            } catch {
                self.event("dl.chase_fail", error: "\(error)")
                if self.playback?.txnId == txnId {
                    // Machine pauses on dry buffer; a fresh eager download
                    // will complete the file for a later archive replay.
                    self.stopPlayback()
                }
            }
        }
    }

    /// The render clock's pull, once per frame interval.
    private func renderTick() -> [Int16]? {
        guard var current = playback else { return nil }
        if !current.separator.isEmpty {
            let frame = current.separator.removeFirst()
            playback = current
            return try? codec.decode(frame)
        }
        if let frame = current.machine.nextFrame() {
            playback = current
            let pcm = try? codec.decode(frame)
            if current.machine.state == .complete {
                playback = current
                finishCurrentMessage()
            }
            return pcm
        }
        playback = current
        if current.machine.state == .complete {
            finishCurrentMessage()
        }
        return nil // buffering or paused: silence
    }

    /// First playback completed: heard receipt (user-scoped — the pendant
    /// drops it from its queue too), telemetry, then the next unheard with a
    /// separator in between (§1.4), or wind down.
    private func finishCurrentMessage() {
        guard let finished = playback else { return }
        if var stored = messages.message(circleId: circleId, txnId: finished.txnId),
           !stored.heard {
            stored.heard = true
            messages.upsert(circleId: circleId, stored)
            publishReceipt(txnId: finished.txnId, patch: ["heard_at": .int(now())])
        }
        let stats = finished.machine.stats
        if let payload = try? ControlWire.encode(ClientStats(
            txnId: finished.txnId, underruns: stats.underruns,
            minBufferMs: stats.minBufferMs == .max ? 0 : stats.minBufferMs,
            startBufferMs: stats.startBufferMs)) {
            signal.publish(payload)
        }
        event("play.done", state: finished.txnId)

        if messages.index(circleId: circleId).contains(where: { !$0.heard }) {
            playback?.separator = separatorFrames()
            playNextInQueue(startingFresh: false)
        } else {
            stopPlayback()
        }
    }

    private func stopPlayback() {
        guard playback != nil else {
            recomputeLed()
            return
        }
        audio.stopPlayback()
        playback = nil
        recomputeLed()
    }

    /// ~180 ms of soft 550 Hz tone between queued messages — inside an
    /// already-running playback, so the silent attention model holds.
    private func separatorFrames() -> [Data] {
        let samples = codec.samplesPerFrame
        return (0 ..< 3).compactMap { index in
            let pcm = (0 ..< samples).map { i -> Int16 in
                let t = Double(index * samples + i) / Double(VoiceConfig.sampleRate)
                let envelope = sin(.pi * Double(index * samples + i)
                                   / Double(3 * samples)) // fade in/out
                return Int16(2500 * envelope * sin(2 * .pi * 550 * t))
            }
            return try? codec.encode(pcm)
        }
    }

    // MARK: - Receipts out

    private func publishReceipt(txnId: String, patch: [String: JSONValue]) {
        guard let payload = try? ControlWire.encode(ReceiptPatch(txnId: txnId, patch: patch)) else {
            return
        }
        signal.publish(payload)
    }

    // MARK: - LED

    private func recomputeLed() {
        let led: Led
        if let record {
            led = record.state == .recording ? .recording : .uploading
        } else if playback != nil {
            led = .playing
        } else if !openTransmissions.isEmpty {
            led = .incoming
        } else if unheardCount > 0 {
            led = .unheard(unheardCount)
        } else if signalState != .connected {
            led = .offline
        } else {
            led = .idle
        }
        if led != lastLed {
            lastLed = led
            onLed?(led)
        }
    }
}
