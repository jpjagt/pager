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

    private func syncFromSession() {
        text = session.text
        draftImage = session.draftImageData
        detectedURLs = session.detectedURLs
        previewLoader.load(urls: detectedURLs.map(\.url))
    }

    /// ⌘V with an image (or image file) on the pasteboard. The image becomes
    /// the DRAFT — committed like typed text. Returns whether the pasteboard
    /// held an image we took; false means the caller should let the text field
    /// handle the paste natively.
    @discardableResult
    func pasteFromGeneralPasteboard() -> Bool {
        let pasteboard = NSPasteboard.general
        var imageDatas: [Data] = []
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { imageDatas.append(data) }
        }
        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        for url in fileURLs {
            if let data = try? Data(contentsOf: url) { imageDatas.append(data) }
        }
        guard case .image(let raw)? = DropPayloadClassifier.classify(
            imageDatas: imageDatas, strings: []) else { return false }
        do {
            try session.setImage(raw)
            draftImage = session.draftImageData
            text = ""
            detectedURLs = []
        } catch {
            // Same signal the menu-bar drop path gives for an unreadable
            // image; the device has no error row to put a message in.
            NSSound.beep()
        }
        return true
    }

    private var pasteMonitor: Any?

    /// Installed while the pager's window is open. ⌘V never reaches SwiftUI's
    /// `onPasteCommand`: the Edit menu's key equivalent dispatches `paste:` to
    /// the field editor (first responder), which beeps on an image-only
    /// pasteboard. This monitor intercepts ⌘V first, takes the image if there
    /// is one, and passes everything else through to the text field. Verified
    /// still necessary against a key `PagerWindow` (Task 9), not just the
    /// popover it was written for.
    func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  event.window?.isKeyWindow == true,
                  (event.window as? PagerWindow)?.linkId == self.linkId
            else { return event }
            return self.pasteFromGeneralPasteboard() ? nil : event
        }
    }

    func removePasteMonitor() {
        if let monitor = pasteMonitor { NSEvent.removeMonitor(monitor) }
        pasteMonitor = nil
    }

    deinit {
        if let monitor = pasteMonitor { NSEvent.removeMonitor(monitor) }
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
