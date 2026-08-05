import Foundation
import Combine

/// Source of truth for configured links. Persists to UserDefaults as JSON.
public final class LinkStore: ObservableObject {
    private enum Keys {
        static let links = "pager.links"
        static let deviceId = "pager.deviceId"
        static let nicknameCounter = "pager.nicknameCounter"
    }

    @Published public private(set) var links: [PagerLink]
    public let deviceId: String
    private let defaults: UserDefaults
    private let imageCache: ImageDiskCache

    public init(defaults: UserDefaults = .standard,
                imageCache: ImageDiskCache = ImageDiskCache()) {
        self.defaults = defaults
        self.imageCache = imageCache
        if let existing = defaults.string(forKey: Keys.deviceId) {
            deviceId = existing
        } else {
            let id = UUID().uuidString
            defaults.set(id, forKey: Keys.deviceId)
            deviceId = id
        }
        if let data = defaults.data(forKey: Keys.links),
           let decoded = try? JSONDecoder().decode([PagerLink].self, from: data) {
            links = decoded
        } else {
            links = []
        }
    }

    @discardableResult
    public func add(code: ShareCode) -> PagerLink {
        let counter = defaults.integer(forKey: Keys.nicknameCounter) + 1
        defaults.set(counter, forKey: Keys.nicknameCounter)
        // Assign a screen color distinct from existing links (until all 7 are
        // in use), so two pagers don't default to the same color.
        let screenColor = ScreenColor.nextUnused(taken: links.map { $0.appearance.screenColor })
        let appearance = AppearancePrefs(screenColor: screenColor)
        let link = PagerLink(code: code.full, nickname: "Pager \(counter)", appearance: appearance)
        links.append(link)
        save()
        return link
    }

    public func remove(id: UUID) {
        links.removeAll { $0.id == id }
        imageCache.remove(for: id)
        save()
    }

    public func update(_ link: PagerLink) {
        guard let index = links.firstIndex(where: { $0.id == link.id }) else { return }
        links[index] = link
        save()
    }

    /// Updates user-editable metadata without touching the cached text, so a
    /// stale UI snapshot can never clobber a newer synced message.
    public func updateMeta(id: UUID, nickname: String, appearance: AppearancePrefs) {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        links[index].nickname = nickname
        links[index].appearance = appearance
        save()
    }

    /// Text convenience over updateCachedContent (existing call sites keep working).
    public func updateCachedText(id: UUID, text: String, writtenAt: Int64) {
        updateCachedContent(id: id, content: .text(text), writtenAt: writtenAt)
    }

    /// Single write path for cached content. Text clears any cached image;
    /// an image empties cachedText and writes the bytes to disk.
    public func updateCachedContent(id: UUID, content: PagerContent, writtenAt: Int64) {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        switch content {
        case .text(let text):
            links[index].cachedText = text
            links[index].cachedIsImage = false
            imageCache.remove(for: id)
        case .image(let data):
            links[index].cachedText = ""
            links[index].cachedIsImage = true
            imageCache.write(data, for: id)
        }
        links[index].cachedWrittenAt = writtenAt
        save()
    }

    /// The cached content for a link (menu bar truth). Falls back to text if
    /// the image file is missing (e.g. deleted by the OS).
    public func cachedContent(id: UUID) -> PagerContent {
        guard let link = links.first(where: { $0.id == id }) else { return .text("") }
        if link.cachedIsImage, let data = imageCache.read(for: id) { return .image(data) }
        return .text(link.cachedText)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(links) {
            defaults.set(data, forKey: Keys.links)
        }
    }
}
