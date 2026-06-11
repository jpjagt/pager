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

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        let link = PagerLink(code: code.full, nickname: "Pager \(counter)")
        links.append(link)
        save()
        return link
    }

    public func remove(id: UUID) {
        links.removeAll { $0.id == id }
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

    public func updateCachedText(id: UUID, text: String, writtenAt: Int64) {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        links[index].cachedText = text
        links[index].cachedWrittenAt = writtenAt
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(links) {
            defaults.set(data, forKey: Keys.links)
        }
    }
}
