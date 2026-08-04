import Foundation

/// The commit seam. `SyncEngine` is the real implementation; tests/e2e inject a
/// stub. Keeps `EditorSession` free of any network/engine internals.
@MainActor
public protocol ContentCommitter: AnyObject {
    func commitContent(_ content: PagerContent)
}

/// The pure editing logic behind the popover, extracted from `LinkViewModel` so
/// it can be driven headlessly (unit tests + e2e). No AppKit.
///
/// Model: the draft is private. `edit` mutates only the draft — never the store
/// or the committer. `commit` is the single point that pushes (on popover
/// close). Remote values land in the store/menu bar independently and never
/// overwrite a live draft.
@MainActor
public final class EditorSession {
    public private(set) var text: String
    public private(set) var detectedURLs: [TextUtil.URLMatch]

    public static let maxLength = 500

    private let linkId: UUID
    private let store: LinkStore
    private let committer: ContentCommitter
    private let now: () -> Int64
    private var dirty = false

    public init(linkId: UUID, store: LinkStore, committer: ContentCommitter,
                now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.linkId = linkId
        self.store = store
        self.committer = committer
        self.now = now
        let cached = store.links.first(where: { $0.id == linkId })?.cachedText ?? ""
        self.text = cached
        self.detectedURLs = TextUtil.detectURLs(in: cached)
    }

    /// The current shared/remote value (what the menu bar shows). Read-only here
    /// — the draft is never replaced from it while editing.
    public var currentRemoteText: String {
        store.links.first(where: { $0.id == linkId })?.cachedText ?? ""
    }

    /// Updates the private draft only: char cap, URL detection, mark dirty.
    /// Does not write to the store or commit.
    public func edit(_ newText: String) {
        text = newText.count > Self.maxLength ? String(newText.prefix(Self.maxLength)) : newText
        detectedURLs = TextUtil.detectURLs(in: text)
        dirty = true
    }

    /// The single commit point (popover close). Pushes the draft via the
    /// committer and writes it to the cache so the menu bar reflects the just-
    /// sent message (own writes are echo-suppressed, so onText won't do it).
    public func commit() {
        guard dirty else { return }
        dirty = false
        committer.commitContent(.text(text))
        store.updateCachedText(id: linkId, text: text, writtenAt: now())
    }
}
