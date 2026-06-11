import Foundation

/// One per link. Owns the SSE subscription, debounced encrypted writes,
/// LWW conflict resolution, echo suppression, and reconnect/backoff.
/// All callbacks fire on the main actor.
@MainActor
public final class SyncEngine {
    public enum State: Equatable {
        case connected
        case reconnecting
        case offline
    }

    public var onText: ((String, Int64) -> Void)?
    public var onState: ((State) -> Void)?

    public private(set) var state: State = .offline {
        didSet { if state != oldValue { onState?(state) } }
    }

    private let transport: SyncTransport
    private let crypto: PagerCrypto
    private let pathId: String
    private let deviceId: String
    private let now: () -> Int64
    private let debounceMs: UInt64

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
        debounceMs: UInt64 = 300
    ) {
        self.transport = transport
        self.crypto = crypto
        self.pathId = pathId
        self.deviceId = deviceId
        self.now = now
        self.debounceMs = debounceMs
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

    /// Called on every keystroke. Local UI is updated optimistically by the
    /// caller; this schedules the debounced encrypted PUT.
    public func setText(_ text: String) {
        guard let ct = try? crypto.encrypt(text) else { return }
        pending = PagerValue(ct: ct, writtenAt: now(), updatedBy: deviceId)
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.debounceMs * 1_000_000)
            guard !Task.isCancelled else { return }
            self.scheduleFlush()
        }
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
                scheduleFlush()
                return
            }
            self.pending = nil
        }
        guard let remote else { return }
        if remote.updatedBy == deviceId {
            // Our echo: record, don't re-deliver. Out-of-order older echoes
            // must not regress lastApplied.
            if LWW.wins(remote, over: lastApplied) {
                lastApplied = remote
            }
            return
        }
        guard LWW.wins(remote, over: lastApplied) else { return }
        lastApplied = remote
        // Undecryptable (corrupt/tampered): keep last good text.
        if let text = crypto.decrypt(remote.ct) {
            onText?(text, remote.writtenAt)
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
                state = .reconnecting
                try? await Task.sleep(nanoseconds: UInt64(backoff.nextDelay() * 1_000_000_000))
            }
        }
    }
}
