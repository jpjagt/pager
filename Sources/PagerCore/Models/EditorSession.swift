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
    /// Armed while the window has just opened: the first typed characters
    /// replace what the pager holds instead of appending to it. See
    /// `beginFreshEdit()`.
    private var armed = false
    /// What an armed replacement threw away, kept so it can be put back — the
    /// wipe is silent and otherwise unrecoverable. Cleared by `endFreshEdit()`,
    /// `restoreReplaced()`, and every explicit verb (`clear`/`discard`/`commit`).
    private var replaced: PagerContent?

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

    /// Text arriving whole — a drop onto the device, not typing at the caret.
    /// Explicit enough to end the open-fresh window: the user said what the
    /// pager should hold, so the next keystroke must not wipe it.
    public func replaceText(_ newText: String) {
        endFreshEdit()
        edit(newText)
    }

    // MARK: - Open-fresh replacement

    /// Called when a pager window opens: the next character typed starts a new
    /// message instead of appending to the old one. Deliberately *not* a
    /// selection in the text field — the caret sits at the end and nothing on
    /// the LCD changes until a key is actually pressed.
    public func beginFreshEdit() {
        armed = true
        replaced = nil
    }

    /// Whether the next typed character should start a new message.
    public var isArmedForFreshEdit: Bool { armed }

    /// Empties the draft in front of the first typed character, remembering
    /// what it held so ⌘Z can bring it back. Returns whether anything was
    /// actually thrown away — false for an already-empty pager, and for a
    /// session that isn't armed.
    ///
    /// This has to happen *before* the keystroke, and the caller has to clear
    /// the text field to match: a binding that shortens the value mid-edit is
    /// silently ignored by SwiftUI's `TextField`, which then re-syncs this
    /// session from its own unwiped string on the following keystroke.
    @discardableResult
    public func takeFreshEdit() -> Bool {
        guard armed else { return false }
        armed = false
        guard !content.isEmpty else { return false }
        replaced = content
        content = .text("")
        detectedURLs = []
        dirty = true
        return true
    }

    /// The user placed the caret themselves (a click in the window): typing is
    /// now editing, not starting over. The replaced content stays restorable —
    /// clicking around is not a reason to lose the ⌘Z.
    public func cancelReplaceOnType() {
        armed = false
    }

    /// Ends the whole grace period: typing appends, and nothing is offered
    /// back. The timeout lands here, as does every explicit verb.
    public func endFreshEdit() {
        armed = false
        replaced = nil
    }

    /// Whether `restoreReplaced()` currently has something to put back.
    public var canRestoreReplaced: Bool { replaced != nil }

    /// Undoes an armed replacement, bringing back the text or image it threw
    /// away — including everything typed since, which is the point (⌘Z on a
    /// wipe the user didn't ask for). No-op, returning false, when there is
    /// nothing to restore.
    @discardableResult
    public func restoreReplaced() -> Bool {
        guard let replaced else { return false }
        self.replaced = nil
        armed = false
        content = replaced
        detectedURLs = TextUtil.detectURLs(in: replaced.textValue)
        dirty = true
        return true
    }

    /// Replaces the draft with a processed image (downscaled, JPEG ≤ 600 KB).
    /// Throws ImageCodecError on unreadable data; the draft is untouched then.
    public func setImage(_ raw: Data) throws {
        let jpeg = try ImageCodec.process(raw)
        content = .image(jpeg)
        detectedURLs = []
        dirty = true
        // Dropping/pasting an image is an explicit "make it this" — nothing
        // was wiped behind the user's back, so there is nothing to offer back.
        endFreshEdit()
    }

    /// The `C` key: empties the draft — text and image — but leaves it dirty.
    /// The user is still editing; nothing is committed. Generalizes the former
    /// `clearImage()`, which only reset an image draft.
    public func clear() {
        content = .text("")
        detectedURLs = []
        dirty = true
        endFreshEdit()
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
        endFreshEdit()
    }

    /// The single commit point. Pushes the draft via the committer and writes it
    /// to the cache so the menu bar reflects the just-sent content (own writes
    /// are echo-suppressed, so onContent won't do it).
    public func commit() {
        guard dirty else { return }
        dirty = false
        endFreshEdit() // the message is out; the replaced one is history
        committer.commitContent(content)
        store.updateCachedContent(id: linkId, content: content, writtenAt: now())
    }
}
