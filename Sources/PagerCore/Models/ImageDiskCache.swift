import Foundation

/// Decrypted image bytes cached on disk, one file per link (UserDefaults would
/// bloat with ~500 KB blobs). Same trust boundary as `cachedText`: plaintext at
/// rest is by design — encryption exists only at the network boundary.
public final class ImageDiskCache: @unchecked Sendable {
    private let directory: URL

    /// ~/Library/Application Support/Pager/images
    public static let defaultDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pager/images")

    public init(directory: URL = ImageDiskCache.defaultDirectory) {
        self.directory = directory
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).jpg")
    }

    public func write(_ data: Data, for id: UUID) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: id), options: .atomic)
    }

    public func read(for id: UUID) -> Data? {
        try? Data(contentsOf: url(for: id))
    }

    public func remove(for id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}
