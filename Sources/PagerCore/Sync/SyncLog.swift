import Foundation

/// A sink for sync-lifecycle events. Implementations must be safe to call from
/// the main actor (the engine runs there). Events carry only what the server
/// already sees — ciphertext, path ids, device ids, timestamps, decisions —
/// never plaintext, the share code, or the derived key.
public protocol SyncLogSink: Sendable {
    func log(_ event: SyncLogEvent)
}

/// One JSONL line. Fields are event-specific; nil fields are omitted on encode.
/// The `t` (ISO-8601) timestamp is stamped by the sink at log time.
public struct SyncLogEvent: Codable, Equatable {
    public var t: String?
    public var ev: String
    /// First 8 hex of the pathId — correlates a line to a link.
    public var link: String?
    public var writtenAt: Int64?
    public var pendingWa: Int64?
    public var remoteWa: Int64?
    public var lastWa: Int64?
    public var remoteBy: String?
    public var len: Int?
    public var ct: String?
    /// Byte length of image ciphertext when `ct` itself is omitted (never log
    /// image ciphertext — see `ctFields` in `SyncEngine`).
    public var ctLen: Int?
    public var state: String?
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case t, ev, link, writtenAt
        case pendingWa = "pending_wa"
        case remoteWa = "remote_wa"
        case lastWa = "last_wa"
        case remoteBy = "remote_by"
        case len, ct
        case ctLen = "ct_len"
        case state, error
    }

    public init(ev: String, link: String? = nil, writtenAt: Int64? = nil,
                pendingWa: Int64? = nil, remoteWa: Int64? = nil, lastWa: Int64? = nil,
                remoteBy: String? = nil, len: Int? = nil, ct: String? = nil,
                ctLen: Int? = nil, state: String? = nil, error: String? = nil, t: String? = nil) {
        self.ev = ev
        self.link = link
        self.writtenAt = writtenAt
        self.pendingWa = pendingWa
        self.remoteWa = remoteWa
        self.lastWa = lastWa
        self.remoteBy = remoteBy
        self.len = len
        self.ct = ct
        self.ctLen = ctLen
        self.state = state
        self.error = error
        self.t = t
    }
}

/// Default sink: discards everything. Keeps `SyncEngine` constructible without
/// a log (existing tests, any non-app caller).
public struct NoopSyncLog: SyncLogSink {
    public init() {}
    public func log(_ event: SyncLogEvent) {}
}

/// Appends events as JSONL to a file on a private serial queue. When the file
/// reaches `maxBytes` it is started fresh (the old contents are dropped — we
/// keep no rotated copy). Privacy: callers must pass only non-sensitive fields.
public final class FileSyncLog: SyncLogSink, @unchecked Sendable {
    private let url: URL
    private let maxBytes: Int
    private let timestamp: @Sendable () -> String
    private let queue = DispatchQueue(label: "pager.synclog")
    private let encoder = JSONEncoder()

    public init(url: URL, maxBytes: Int = 2 * 1024 * 1024,
                timestamp: @escaping @Sendable () -> String = { FileSyncLog.isoNow() }) {
        self.url = url
        self.maxBytes = maxBytes
        self.timestamp = timestamp
    }

    public func log(_ event: SyncLogEvent) {
        var stamped = event
        stamped.t = timestamp()
        queue.async { [self] in write(stamped) }
    }

    private func write(_ event: SyncLogEvent) {
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A) // newline

        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)

        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size == 0 || size + line.count > maxBytes {
            try? line.write(to: url, options: .atomic) // start fresh
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? line.write(to: url, options: .atomic)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// ISO-8601 with millisecond precision, e.g. 2026-06-23T15:22:01.345Z.
    public static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
