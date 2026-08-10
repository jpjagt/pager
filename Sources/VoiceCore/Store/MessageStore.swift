import Foundation

/// One transmission as persisted locally: metadata in a per-circle JSON
/// index, audio as a raw VLK1 stream file next to it (no transcoding — the
/// wire bytes are the archive).
public struct StoredMessage: Codable, Equatable {
    public var txnId: String
    public var txIndex: Int64
    /// Sending device (`vpd-…`); resolves to a user via `CircleConfig`.
    public var sender: String
    public var frameMs: Int
    public var heard: Bool
    public var saved: Bool
    public var durationMs: Int64?

    public init(txnId: String, txIndex: Int64, sender: String,
                frameMs: Int = VoiceConfig.frameMs, heard: Bool = false,
                saved: Bool = false, durationMs: Int64? = nil) {
        self.txnId = txnId
        self.txIndex = txIndex
        self.sender = sender
        self.frameMs = frameMs
        self.heard = heard
        self.saved = saved
        self.durationMs = durationMs
    }
}

/// Per-circle message persistence with a disk budget instead of an expiry
/// timer (pendant spec §1.4: deterministic capacity beats expiry rules).
/// Eviction never touches unheard messages, locally saved ones, or the most
/// recent message — within what remains, oldest `tx_index` goes first.
public final class MessageStore {
    private let baseURL: URL
    private let diskBudgetBytes: Int

    /// ~Library/Application Support/Pager/Voice.
    public static func defaultBaseURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pager/Voice", isDirectory: true)
    }

    public init(baseURL: URL = MessageStore.defaultBaseURL(),
                diskBudgetBytes: Int = 512 * 1024 * 1024) {
        self.baseURL = baseURL
        self.diskBudgetBytes = diskBudgetBytes
    }

    // MARK: - Index

    /// All known messages for a circle, ascending `tx_index` (queue order).
    public func index(circleId: UUID) -> [StoredMessage] {
        guard let data = try? Data(contentsOf: indexURL(circleId)),
              let decoded = try? JSONDecoder().decode([StoredMessage].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.txIndex < $1.txIndex }
    }

    /// Inserts or replaces by `txnId`, then enforces the disk budget.
    public func upsert(circleId: UUID, _ message: StoredMessage) {
        var entries = index(circleId: circleId)
        entries.removeAll { $0.txnId == message.txnId }
        entries.append(message)
        writeIndex(circleId: circleId, entries)
        enforceBudget(circleId: circleId)
    }

    public func message(circleId: UUID, txnId: String) -> StoredMessage? {
        index(circleId: circleId).first { $0.txnId == txnId }
    }

    public func remove(circleId: UUID, txnId: String) {
        var entries = index(circleId: circleId)
        entries.removeAll { $0.txnId == txnId }
        writeIndex(circleId: circleId, entries)
        try? FileManager.default.removeItem(at: audioURL(circleId, txnId))
    }

    public func removeCircle(circleId: UUID) {
        try? FileManager.default.removeItem(at: circleDir(circleId))
    }

    // MARK: - Audio

    public func writeAudio(circleId: UUID, txnId: String, bytes: Data) {
        let dir = circleDir(circleId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? bytes.write(to: audioURL(circleId, txnId), options: .atomic)
        enforceBudget(circleId: circleId)
    }

    public func readAudio(circleId: UUID, txnId: String) -> Data? {
        try? Data(contentsOf: audioURL(circleId, txnId))
    }

    public func hasAudio(circleId: UUID, txnId: String) -> Bool {
        FileManager.default.fileExists(atPath: audioURL(circleId, txnId).path)
    }

    // MARK: - Eviction

    private func enforceBudget(circleId: UUID) {
        var entries = index(circleId: circleId)
        guard let newest = entries.map(\.txIndex).max() else { return }
        var total = entries.reduce(0) { $0 + audioSize(circleId, $1.txnId) }
        guard total > diskBudgetBytes else { return }
        for entry in entries.sorted(by: { $0.txIndex < $1.txIndex }) {
            guard total > diskBudgetBytes else { break }
            guard entry.heard, !entry.saved, entry.txIndex != newest else { continue }
            total -= audioSize(circleId, entry.txnId)
            try? FileManager.default.removeItem(at: audioURL(circleId, entry.txnId))
            entries.removeAll { $0.txnId == entry.txnId }
        }
        writeIndex(circleId: circleId, entries)
    }

    private func audioSize(_ circleId: UUID, _ txnId: String) -> Int {
        (try? FileManager.default.attributesOfItem(
            atPath: audioURL(circleId, txnId).path)[.size] as? Int).flatMap { $0 } ?? 0
    }

    // MARK: - Paths

    private func circleDir(_ circleId: UUID) -> URL {
        baseURL.appendingPathComponent(circleId.uuidString, isDirectory: true)
    }

    private func indexURL(_ circleId: UUID) -> URL {
        circleDir(_: circleId).appendingPathComponent("index.json")
    }

    private func audioURL(_ circleId: UUID, _ txnId: String) -> URL {
        circleDir(_: circleId).appendingPathComponent("\(txnId).vlk")
    }

    private func writeIndex(circleId: UUID, _ entries: [StoredMessage]) {
        let dir = circleDir(circleId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: indexURL(circleId), options: .atomic)
        }
    }
}
