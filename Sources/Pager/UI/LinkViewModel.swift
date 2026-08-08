import SwiftUI
import Combine
import AppKit
import PagerCore

/// Thin SwiftUI bridge over `EditorSession`. Holds the private draft, mirrors
/// the offline hint and the link's appearance, and forwards edits/commit.
/// Remote updates reach the menu bar through the store/engine path, not through
/// this view model — a live draft is never overwritten.
@MainActor
final class LinkViewModel: ObservableObject {
    @Published var text: String
    @Published var showOfflineHint = false
    @Published var detectedURLs: [TextUtil.URLMatch]
    @Published var draftImage: Data?
    /// Mirrors the link's stored appearance so a theme change in Settings
    /// re-themes an open window without reopening it.
    @Published private(set) var appearance: AppearancePrefs
    let previewLoader = ImageURLPreviewLoader()

    let linkId: UUID
    private let session: EditorSession
    private let engine: SyncEngine?
    private var hintTask: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    /// The `···` key. The app shell pops the AppKit menu.
    var onOpenMenu: (() -> Void)?
    /// "this pager is done being edited" — the app shell closes its window.
    var onRequestClose: (() -> Void)?

    init(link: PagerLink, store: LinkStore, engine: SyncEngine?) {
        self.linkId = link.id
        self.engine = engine
        self.appearance = link.appearance
        // No engine (e.g. transport unavailable): commit is a no-op sink.
        let committer: ContentCommitter = engine ?? NoopCommitter()
        self.session = EditorSession(linkId: link.id, store: store, committer: committer)
        self.text = session.text
        self.detectedURLs = session.detectedURLs
        self.draftImage = session.draftImageData
        previewLoader.load(urls: session.detectedURLs.map(\.url))

        let linkId = link.id
        store.$links
            .compactMap { $0.first(where: { $0.id == linkId })?.appearance }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prefs in self?.appearance = prefs }
            .store(in: &cancellables)

        engine?.onState = { [weak self] state in
            Task { @MainActor in self?.stateChanged(state) }
        }
        if let engine { stateChanged(engine.state) }
    }

    /// The device view's `onTextChange`. Keeps `detectedURLs`/cap in sync with
    /// the session after it has processed the edit. The guard skips
    /// programmatic syncs (e.g. text set to "" after an image paste) — only a
    /// real user edit may replace an image draft.
    func setText(_ newText: String) {
        guard newText != session.text else {
            text = newText
            return
        }
        session.edit(newText)
        text = session.text // reflects the char cap
        detectedURLs = session.detectedURLs
        draftImage = nil
        previewLoader.load(urls: detectedURLs.map(\.url))
    }

    /// Enter, or the send key: push the draft and let the window go.
    func submit() {
        commit()
        onRequestClose?()
    }

    /// The ✕ key: abandon the edit, keeping whatever is already shared.
    func dismiss() {
        session.discard()
        syncFromSession()
        onRequestClose?()
    }

    /// The `C` key: empty the draft but stay open and still editing.
    func clear() {
        session.clear()
        syncFromSession()
    }

    // MARK: - Open-fresh editing

    /// How long after opening a pager typing still means "start a new message"
    /// rather than "append to this one". Long enough to read what's on screen
    /// and decide, short enough that a window left open is a normal editor
    /// again by the time you come back to it.
    private static let freshEditGrace: TimeInterval = 10

    /// The window just opened: arm the session so the first characters typed
    /// replace the message, and start the clock that ends that.
    func beginFreshEdit() {
        session.beginFreshEdit()
        graceTask?.cancel()
        graceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.freshEditGrace * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.session.endFreshEdit()
        }
    }

    /// A click inside the window: the caret is where the user put it, so typing
    /// is editing. ⌘Z can still bring back an already-replaced message.
    func cancelReplaceOnType() {
        session.cancelReplaceOnType()
    }

    /// Runs just before a key press reaches the message field. On the first
    /// typed character of a freshly opened pager the old message is cleared —
    /// in the field editor as well as the session — so the character lands in
    /// an empty field. Anything that isn't typing (arrows, delete, escape)
    /// means the user is working on what's there, and ends the window instead.
    private func prepareForFirstKeystroke(_ event: NSEvent, in window: PagerWindow) {
        guard session.isArmedForFreshEdit else { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard TypingKey.isInsertion(characters: event.characters,
                                    hasNonShiftModifier: !modifiers.subtracting(.shift).isEmpty) else {
            session.cancelReplaceOnType()
            return
        }
        guard session.takeFreshEdit() else { return }
        window.setMessageFieldText("")
        syncFromSession()
    }

    /// ⌘Z after the first keystroke wiped the old message (or image). Returns
    /// false when there is nothing of ours to undo, so the field editor's own
    /// undo can handle the shortcut instead.
    private func restoreReplacedContent(in window: PagerWindow) -> Bool {
        guard session.restoreReplaced() else { return false }
        syncFromSession()
        // Same reason the wipe goes through the window: the field is mid-edit,
        // so the restored message has to be written into the field editor.
        window.setMessageFieldText(session.text)
        return true
    }

    private func syncFromSession() {
        text = session.text
        draftImage = session.draftImageData
        detectedURLs = session.detectedURLs
        previewLoader.load(urls: detectedURLs.map(\.url))
    }

    /// ⌘V with an image (or image file) on the pasteboard. The image becomes
    /// the DRAFT — committed like typed text. Returns whether the pasteboard
    /// held an image we took; false means the caller should let the text field
    /// handle the paste natively (text pastes are the field's own business).
    @discardableResult
    func pasteFromGeneralPasteboard() -> Bool {
        guard case .image(let raw)? = PasteboardPayload.read(NSPasteboard.general) else {
            return false
        }
        take(.image(raw))
        return true
    }

    /// A drop onto the pager window. Everything readable off the drag, left to
    /// the same classifier the menu-bar drop and ⌘V use — but landing in the
    /// draft rather than being sent, because the window is the editing surface.
    func accept(imageDatas: [Data], strings: [String]) {
        guard let payload = DropPayloadClassifier.classify(
            imageDatas: imageDatas, strings: strings) else {
            NSSound.beep() // nothing here we can hold
            return
        }
        take(payload)
    }

    private func take(_ payload: DropPayload) {
        switch payload {
        case .image(let raw):
            do {
                try session.setImage(raw)
            } catch {
                // Same signal the menu-bar drop path gives for an unreadable
                // image; the device has no error row to put a message in.
                NSSound.beep()
                return
            }
        case .text(let dropped):
            // Replaces the draft outright rather than inserting at the caret:
            // a pager holds one short message, and the drop landed on the
            // device, not at a text position.
            session.replaceText(dropped)
        }
        syncFromSession()
    }

    private var keyMonitor: Any?

    /// Installed while the pager's window is open. Sees every key press before
    /// the text field does, which is the only place three things can happen:
    ///
    /// - **⌘V** never reaches SwiftUI's `onPasteCommand`: the Edit menu's key
    ///   equivalent dispatches `paste:` to the field editor (first responder),
    ///   which beeps on an image-only pasteboard. Intercepted here so an image
    ///   becomes the draft; anything else falls through to the field.
    /// - **⌘Z** goes to the field editor's own undo stack, which knows nothing
    ///   about the content an open-fresh edit replaced (see `session`). When
    ///   there is something to put back, this takes the shortcut; otherwise the
    ///   field's ordinary undo runs.
    /// - **The first character typed into a just-opened pager** clears the old
    ///   message so the keystroke starts a new one. It has to happen here,
    ///   ahead of the field editor, and not by shortening the value in the
    ///   binding — SwiftUI ignores a shortened value while the field is being
    ///   edited (verified), and the next keystroke then re-syncs this model
    ///   from the field's own unwiped string, which just reads as an append.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.window?.isKeyWindow == true,
                  let window = event.window as? PagerWindow,
                  window.linkId == self.linkId
            else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command {
                switch event.charactersIgnoringModifiers {
                case "v": return self.pasteFromGeneralPasteboard() ? nil : event
                case "z": return self.restoreReplacedContent(in: window) ? nil : event
                default: return event
                }
            }
            self.prepareForFirstKeystroke(event, in: window)
            return event
        }
    }

    func removeKeyMonitor() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
    }

    deinit {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
    }

    /// A tap on the draft image: write the JPEG to a temp file and hand it to
    /// the system, which opens it in Preview. The LCD only ever shows a small
    /// downscaled copy, so this is the only way to actually look at it.
    func openDraftImage() {
        guard let data = draftImage else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(linkId.uuidString).jpg")
        try? data.write(to: url, options: .atomic)
        NSWorkspace.shared.open(url)
    }

    /// Pushes the draft.
    func commit() { session.commit() }

    /// Offline hint with a 2 s grace period so routine reconnects don't flash it.
    private func stateChanged(_ state: SyncEngine.State) {
        hintTask?.cancel()
        if state == .connected {
            showOfflineHint = false
        } else {
            hintTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                self?.showOfflineHint = true
            }
        }
    }
}

/// Used when there is no engine: edits are held locally, commit goes nowhere.
@MainActor
private final class NoopCommitter: ContentCommitter {
    func commitContent(_ content: PagerContent) {}
}
