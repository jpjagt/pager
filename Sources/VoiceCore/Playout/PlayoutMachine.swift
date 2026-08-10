import Foundation

/// Post-playback telemetry (§7.3) — the numbers that tune `N_start`.
public struct PlayoutStats: Equatable {
    public var underruns = 0
    public var minBufferMs = Int.max
    public var startBufferMs = 0
}

/// The §1.2 playout policy, as a pure machine. Encoded frames go in as they
/// arrive (from the live stream or from disk — the machine cannot tell,
/// which is the point: chase-play and archive-play are one code path). A
/// render clock calls `nextFrame()` every `frameMs`; whatever it returns is
/// decoded and played. All pacing lives in the caller's clock, all policy
/// lives here.
///
/// Rules (pendant spec §1.2):
/// - BUFFERING exits on `buffer ≥ N_start` **or** end-of-message, whichever
///   comes first — a short message never waits for a long threshold.
/// - Underrun with the transmission still open: silent pause, rebuffer to
///   `N_resume`, resume. No time-stretch, no concealment, no filler.
/// - The buffer may grow without bound; playout stays realtime-paced.
public struct PlayoutMachine {
    public enum State: Equatable {
        case idle
        case buffering
        case playing
        case paused
        case complete
    }

    public private(set) var state: State = .idle
    public private(set) var stats = PlayoutStats()

    private var queue: [Data] = []
    private var eomReceived = false
    private let frameMs: Int
    private let startThresholdMs: Int
    private let resumeThresholdMs: Int

    public init(frameMs: Int = VoiceConfig.frameMs,
                startThresholdMs: Int = VoiceConfig.playoutStartMs,
                resumeThresholdMs: Int = VoiceConfig.playoutResumeMs) {
        self.frameMs = frameMs
        self.startThresholdMs = startThresholdMs
        self.resumeThresholdMs = resumeThresholdMs
    }

    /// Frame count × frame duration — no decoding needed to measure depth.
    public var bufferedMs: Int { queue.count * frameMs }

    /// The user's tap. Frames may already be queued (archive play, or a cue
    /// that arrived before the tap): thresholds are checked immediately.
    public mutating func begin() {
        guard state == .idle || state == .complete else { return }
        state = .buffering
        stats = PlayoutStats()
        maybeStart()
    }

    /// The user's tap during playback. Clears everything — a stopped message
    /// is done; replaying it later is a fresh archive play from disk.
    public mutating func stop() {
        state = .idle
        queue.removeAll()
        eomReceived = false
    }

    public mutating func receive(_ frame: Data) {
        queue.append(frame)
        maybeStart()
        maybeResume()
    }

    public mutating func endOfMessage() {
        eomReceived = true
        // EOM ends any wait: a 1.5 s message never waits for a 2 s buffer,
        // and a pause with nothing more coming should drain, not sit.
        maybeStart()
        maybeResume()
    }

    /// Called by the render clock once per `frameMs` while it wants audio.
    /// nil means "render silence and check back" (buffering/paused) or
    /// "stop the clock" (complete/idle).
    public mutating func nextFrame() -> Data? {
        guard state == .playing else { return nil }
        guard !queue.isEmpty else {
            if eomReceived {
                state = .complete
            } else {
                state = .paused
                stats.underruns += 1
            }
            return nil
        }
        let frame = queue.removeFirst()
        stats.minBufferMs = min(stats.minBufferMs, bufferedMs)
        if queue.isEmpty && eomReceived {
            state = .complete // this frame is the last; play it and stop
        }
        return frame
    }

    private mutating func maybeStart() {
        guard state == .buffering else { return }
        if bufferedMs >= startThresholdMs || eomReceived {
            stats.startBufferMs = bufferedMs
            stats.minBufferMs = bufferedMs
            state = .playing
        }
    }

    private mutating func maybeResume() {
        guard state == .paused else { return }
        if bufferedMs >= resumeThresholdMs || eomReceived {
            state = .playing
        }
    }
}
