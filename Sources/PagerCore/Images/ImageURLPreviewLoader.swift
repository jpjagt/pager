import Foundation

/// Mode 4: a text message contains an image URL → lazily fetch it when the
/// popover opens and show a preview. Pure presentation — nothing on the wire.
/// Fetching happens on the RECEIVER at display time (a sender-side flag would
/// save nothing: the receiver still has to fetch, and stored flags go stale).
@MainActor
public final class ImageURLPreviewLoader: ObservableObject {
    public struct Preview: Equatable {
        public let url: URL
        public let data: Data
    }

    @Published public private(set) var preview: Preview?

    public typealias Fetch = @Sendable (URL) async throws -> Data

    private let fetch: Fetch
    private var task: Task<Void, Never>?

    /// Session-lifetime cache so reopening the popover is instant.
    private static var cache: [URL: Data] = [:]
    private static var cacheOrder: [URL] = []
    private static let cacheCapacity = 20

    public init(fetch: @escaping Fetch = ImageURLPreviewLoader.urlSessionFetch) {
        self.fetch = fetch
    }

    /// Tries the URLs in order; the first response that decodes as an image
    /// wins. Failures are silent (the popover just shows the link row).
    public func load(urls: [URL]) {
        task?.cancel()
        preview = nil
        let candidates = urls.filter { $0.scheme == "http" || $0.scheme == "https" }
        guard !candidates.isEmpty else { return }
        for url in candidates {
            if let data = Self.cache[url] {
                preview = Preview(url: url, data: data)
                return
            }
        }
        task = Task { [fetch] in
            for url in candidates {
                guard !Task.isCancelled else { return }
                guard let data = try? await fetch(url),
                      ImageCodec.isDecodableImage(data) else { continue }
                Self.store(data, for: url)
                preview = Preview(url: url, data: data)
                return
            }
        }
    }

    private static func store(_ data: Data, for url: URL) {
        if cache[url] == nil {
            cacheOrder.append(url)
            if cacheOrder.count > cacheCapacity {
                cache[cacheOrder.removeFirst()] = nil
            }
        }
        cache[url] = data
    }

    public static let maxBytes = 10 * 1024 * 1024

    public static let urlSessionFetch: Fetch = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        guard data.count <= maxBytes else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }
}
