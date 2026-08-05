import Foundation

/// One per link. Owns the SSE subscription, debounced encrypted writes,
/// LWW conflict resolution, echo suppression, and reconnect/backoff.
/// All callbacks fire on the main actor.
@MainActor
public final class SyncEngine: ContentCommitter {
    public enum State: Equatable {
        case connected
        case reconnecting
        case offline
    }

    public var onContent: ((PagerContent, Int64) -> Void)?
    public var onState: ((State) -> Void)?

    public private(set) var state: State = .offline {
        didSet {
            if state != oldValue {
                onState?(state)
                event("state", state: "\(state)")
            }
        }
    }

    private let transport: SyncTransport
    private let crypto: PagerCrypto
    private let pathId: String
    private let deviceId: String
    private let now: () -> Int64
    private let debounceMs: UInt64
    private let log: SyncLogSink
    /// First 8 hex of the pathId — tags every log line to this link.
    private let linkTag: String

    private var lastApplied: PagerValue?
    private var pending: PagerValue? // edited locally, not yet accepted by server
    private var streamTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var flushEpoch = 0
    private var backoff = Backoff()

    public init(
        transport: SyncTransport,
        crypto: PagerCrypto,
        pathId: String,
        deviceId: String,
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        debounceMs: UInt64 = 300,
        log: SyncLogSink = NoopSyncLog()
    ) {
        self.transport = transport
        self.crypto = crypto
        self.pathId = pathId
        self.deviceId = deviceId
        self.now = now
        self.debounceMs = debounceMs
        self.log = log
        self.linkTag = String(pathId.prefix(8))
    }

    private func event(_ ev: String, writtenAt: Int64? = nil, pendingWa: Int64? = nil,
                       remoteWa: Int64? = nil, lastWa: Int64? = nil, remoteBy: String? = nil,
                       len: Int? = nil, ct: String? = nil, ctLen: Int? = nil, state: String? = nil,
                       error: String? = nil) {
        log.log(SyncLogEvent(ev: ev, link: linkTag, writtenAt: writtenAt, pendingWa: pendingWa,
                             remoteWa: remoteWa, lastWa: lastWa, remoteBy: remoteBy, len: len,
                             ct: ct, ctLen: ctLen, state: state, error: error))
    }

    /// img ciphertext is ~800 KB — log its length, never its content (the 2 MB
    /// log cap would blow instantly, and decode-log doesn't need it).
    private static func ctFields(_ value: PagerValue) -> (ct: String?, ctLen: Int?) {
        value.type == PagerContent.imageWireType ? (nil, value.ct.count) : (value.ct, nil)
    }

    public func start() {
        streamTask?.cancel()
        streamTask = Task { await runLoop() }
    }

    public func stop() {
        streamTask?.cancel()
        streamTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        flushEpoch += 1 // invalidate every link in the flush chain, not just the head
        flushTask?.cancel()
        flushTask = nil
    }

    /// Immediate reconnect (network path restored / wake from sleep).
    public func reconnectNow() {
        backoff.reset()
        start()
    }

    /// Schedules a debounced encrypted PUT.
    public func setText(_ text: String) {
        guard let ct = try? crypto.encrypt(text) else { return }
        let writtenAt = now()
        pending = PagerValue(ct: ct, writtenAt: writtenAt, updatedBy: deviceId)
        event("edit.set", writtenAt: writtenAt, len: text.count, ct: ct)
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.debounceMs * 1_000_000)
            guard !Task.isCancelled else { return }
            self.scheduleFlush()
        }
    }

    /// Encrypts and flushes immediately, skipping the debounce — the single
    /// commit point (popover close / menu-bar drop).
    public func commitContent(_ content: PagerContent) {
        guard let sealed = try? crypto.encryptContent(content) else { return }
        let writtenAt = now()
        let value = PagerValue(ct: sealed.ct, writtenAt: writtenAt,
                               updatedBy: deviceId, type: sealed.type)
        pending = value
        let fields = Self.ctFields(value)
        event("edit.commit", writtenAt: writtenAt, len: content.sizeForLog,
              ct: fields.ct, ctLen: fields.ctLen)
        debounceTask?.cancel()
        debounceTask = nil
        scheduleFlush()
    }

    /// Text convenience (tests + e2e call sites).
    public func commitText(_ text: String) { commitContent(.text(text)) }

    /// Blocks the caller until the pending write has landed, or `timeout`
    /// elapses. **Only for app termination.** Every other flush goes through
    /// the async chain, but at `applicationWillTerminate` the process is gone
    /// long before a Task's PUT leaves the machine — the normal path debounces
    /// and then awaits, and nothing awaits the app's own death.
    ///
    /// The PUT runs detached precisely so it does *not* need this actor: the
    /// caller is holding the main thread inside `wait()`, so anything that
    /// hopped back to the main actor to finish would deadlock instead of
    /// saving the draft.
    public func flushSynchronously(timeout: TimeInterval = 3) {
        // Stand down the async machinery first; it can only race this write
        // with the identical value, and it will never outlive the process.
        debounceTask?.cancel()
        debounceTask = nil
        flushEpoch += 1
        flushTask?.cancel()
        flushTask = nil

        guard let value = pending else { return }
        pending = nil
        let fields = Self.ctFields(value)
        event("flush.sync_begin", writtenAt: value.writtenAt, ct: fields.ct, ctLen: fields.ctLen)

        let transport = self.transport
        let pathId = self.pathId
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            try? await transport.put(pathId: pathId, value: value)
            done.signal()
        }
        let result = done.wait(timeout: .now() + timeout)
        event(result == .success ? "flush.sync_end" : "flush.sync_timeout", writtenAt: value.writtenAt)
    }

    /// Test hook: inject a pending offline edit without scheduling a flush.
    public func simulatePendingForTesting(writtenAt: Int64, text: String) {
        guard let ct = try? crypto.encrypt(text) else { return }
        pending = PagerValue(ct: ct, writtenAt: writtenAt, updatedBy: deviceId)
    }

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                for try await event in transport.stream(pathId: pathId) {
                    if handle(event) { break }
                }
            } catch is CancellationError {
                return
            } catch {
                event("stream.drop", error: "\(error)")
                // fall through to reconnect
            }
            guard !Task.isCancelled else { return }
            state = .reconnecting
            let delay = backoff.nextDelay()
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private struct PutPayload: Decodable {
        let path: String
        let data: PagerValue?
    }

    /// Returns true when the stream should be abandoned and reconnected
    /// (via the run loop's backoff path).
    private func handle(_ event: SSEEvent) -> Bool {
        switch event.name {
        case "put":
            guard let payload = try? JSONDecoder().decode(
                PutPayload.self, from: Data(event.data.utf8)) else { return false }
            if state != .connected {
                state = .connected
                backoff.reset()
            }
            apply(remote: payload.data)
            return false
        case "keep-alive", "patch":
            return false // we only ever PUT whole nodes; patch can't occur
        case "cancel", "auth_revoked":
            return true // abandon stream; run loop reconnects with backoff
        default:
            return false
        }
    }

    private func apply(remote: PagerValue?) {
        // Pending local edit: either it still wins (push it) or it's stale (drop it).
        if let pending {
            if LWW.wins(pending, over: remote) {
                event("apply.pending_wins", pendingWa: pending.writtenAt, remoteWa: remote?.writtenAt)
                scheduleFlush()
                return
            }
            event("apply.discard_pending", pendingWa: pending.writtenAt,
                  remoteWa: remote?.writtenAt, remoteBy: remote?.updatedBy)
            self.pending = nil
        }
        guard let remote else { return }
        if remote.updatedBy == deviceId {
            // Our echo: record, don't re-deliver. Out-of-order older echoes
            // must not regress lastApplied.
            event("apply.echo", writtenAt: remote.writtenAt)
            if LWW.wins(remote, over: lastApplied) {
                lastApplied = remote
            }
            return
        }
        guard LWW.wins(remote, over: lastApplied) else {
            event("apply.reject_stale", remoteWa: remote.writtenAt, lastWa: lastApplied?.writtenAt)
            return
        }
        lastApplied = remote
        // Undecryptable (corrupt/tampered/not a decodable image): keep last good content.
        let fields = Self.ctFields(remote)
        if let content = crypto.decryptContent(ct: remote.ct, type: remote.type) {
            event("apply.accept", writtenAt: remote.writtenAt, len: content.sizeForLog,
                  ct: fields.ct, ctLen: fields.ctLen)
            onContent?(content, remote.writtenAt)
        } else {
            event("apply.undecryptable", writtenAt: remote.writtenAt,
                  ct: fields.ct, ctLen: fields.ctLen)
        }
    }

    /// Serializes flushes: each one awaits the prior, then re-reads `pending`
    /// (which always holds the newest edit), so an older value can never land
    /// after a newer one from this device. Tracked so `stop()` cancels it.
    private func scheduleFlush() {
        let prior = flushTask
        let epoch = flushEpoch
        flushTask = Task { [weak self] in
            await prior?.value
            await self?.flushPending(epoch: epoch)
        }
    }

    private func flushPending(epoch: Int) async {
        // The epoch check (re-evaluated on the main actor each iteration,
        // including after the backoff sleep) lets stop() halt every link in
        // the chain, not just the one flushTask currently points at.
        while epoch == flushEpoch, let value = pending, !Task.isCancelled {
            do {
                try await transport.put(pathId: pathId, value: value)
                let fields = Self.ctFields(value)
                event("flush.put_ok", writtenAt: value.writtenAt, ct: fields.ct, ctLen: fields.ctLen)
                if pending == value {
                    pending = nil
                    lastApplied = value
                    return
                }
                // A newer edit arrived mid-PUT; loop to flush it now.
            } catch is CancellationError {
                return
            } catch {
                // Stays pending; retried after backoff (or on next snapshot/edit).
                event("flush.put_fail", writtenAt: value.writtenAt, error: "\(error)")
                state = .reconnecting
                try? await Task.sleep(nanoseconds: UInt64(backoff.nextDelay() * 1_000_000_000))
            }
        }
    }
}
