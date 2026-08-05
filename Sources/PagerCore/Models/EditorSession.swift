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
/// Model: the draft is private and holds either text or an image (never both).
/// `edit`/`setImage` mutate only the draft. `commit` is the single point that
/// pushes (popover close, or immediately for a menu-bar drop). Remote values
/// land in the store/menu bar independently and never overwrite a live draft.
@MainActor
public final class EditorSession {
    public private(set) var content: PagerContent
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
        let cached = store.cachedContent(id: linkId)
        self.content = cached
        self.detectedURLs = TextUtil.detectURLs(in: cached.textValue)
    }

    /// The draft's text ("" while the draft is an image).
    public var text: String { content.textValue }

    /// The draft's image bytes (nil while the draft is text).
    public var draftImageData: Data? { content.imageData }

    /// The current shared/remote value (what the menu bar shows). Read-only here
    /// — the draft is never replaced from it while editing.
    public var currentRemoteText: String {
        store.links.first(where: { $0.id == linkId })?.cachedText ?? ""
    }

    /// Updates the private draft only: char cap, URL detection, mark dirty.
    /// Replaces an image draft (a pager holds text OR an image, never both).
    public func edit(_ newText: String) {
        let capped = newText.count > Self.maxLength ? String(newText.prefix(Self.maxLength)) : newText
        content = .text(capped)
        detectedURLs = TextUtil.detectURLs(in: capped)
        dirty = true
    }

    /// Replaces the draft with a processed image (downscaled, JPEG ≤ 600 KB).
    /// Throws ImageCodecError on unreadable data; the draft is untouched then.
    public func setImage(_ raw: Data) throws {
        let jpeg = try ImageCodec.process(raw)
        content = .image(jpeg)
        detectedURLs = []
        dirty = true
    }

    /// The `C` key: empties the draft — text and image — but leaves it dirty.
    /// The user is still editing; nothing is committed. Generalizes the former
    /// `clearImage()`, which only reset an image draft.
    public func clear() {
        content = .text("")
        detectedURLs = []
        dirty = true
    }

    /// The ✕ key: abandons the edit, reverting the draft to the last cached
    /// content and clearing dirty. Reverts to *cached* (not a session-start
    /// snapshot), so a remote update that landed mid-edit wins here — that's
    /// intentional and consistent with last-write-wins.
    public func discard() {
        let cached = store.cachedContent(id: linkId)
        content = cached
        detectedURLs = TextUtil.detectURLs(in: cached.textValue)
        dirty = false
    }

    /// The single commit point. Pushes the draft via the committer and writes it
    /// to the cache so the menu bar reflects the just-sent content (own writes
    /// are echo-suppressed, so onContent won't do it).
    public func commit() {
        guard dirty else { return }
        dirty = false
        committer.commitContent(content)
        store.updateCachedContent(id: linkId, content: content, writtenAt: now())
    }
}
