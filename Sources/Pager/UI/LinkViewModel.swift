import SwiftUI
import Combine
import AppKit
import PagerCore

/// Thin SwiftUI bridge over `EditorSession`. Holds the private draft, mirrors
/// the offline hint, and forwards edits/commit. Remote updates reach the menu
/// bar through the store/engine path, not through this view model — a live
/// draft is never overwritten.
@MainActor
final class LinkViewModel: ObservableObject {
    @Published var text: String
    @Published var showOfflineHint = false
    @Published var detectedURLs: [TextUtil.URLMatch]
    @Published var draftImage: Data?
    @Published var imageError: String?
    let previewLoader = ImageURLPreviewLoader()

    let linkId: UUID
    private let session: EditorSession
    private let engine: SyncEngine?
    private var hintTask: Task<Void, Never>?

    var onOpenSettings: (() -> Void)?
    var onClose: (() -> Void)?

    init(link: PagerLink, store: LinkStore, engine: SyncEngine?) {
        self.linkId = link.id
        self.engine = engine
        // No engine (e.g. transport unavailable): commit is a no-op sink.
        let committer: ContentCommitter = engine ?? NoopCommitter()
        self.session = EditorSession(linkId: link.id, store: store, committer: committer)
        self.text = session.text
        self.detectedURLs = session.detectedURLs
        self.draftImage = session.draftImageData
        previewLoader.load(urls: session.detectedURLs.map(\.url))

        engine?.onState = { [weak self] state in
            Task { @MainActor in self?.stateChanged(state) }
        }
        if let engine { stateChanged(engine.state) }
    }

    /// Called from the view's onChange. Keeps `detectedURLs`/cap in sync with
    /// the session after it has processed the edit. The guard skips
    /// programmatic syncs (e.g. text set to "" after an image paste) — only a
    /// real user edit may replace an image draft.
    func textEdited() {
        guard text != session.text else { return }
        session.edit(text)
        if text != session.text { text = session.text } // reflect the char cap
        detectedURLs = session.detectedURLs
        draftImage = nil
        imageError = nil
        previewLoader.load(urls: detectedURLs.map(\.url))
    }

    /// ⌘V with an image (or image file) on the pasteboard. The image becomes
    /// the DRAFT — committed on popover close, exactly like typed text.
    func pasteFromGeneralPasteboard() {
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
            imageDatas: imageDatas, strings: []) else { return }
        do {
            try session.setImage(raw)
            draftImage = session.draftImageData
            text = ""
            detectedURLs = []
            imageError = nil
        } catch {
            imageError = "couldn't read that image"
        }
    }

    /// The ✕ on the image: back to an empty text draft.
    func clearImage() {
        session.clearImage()
        draftImage = nil
    }

    /// Click on the draft image: hand the bytes to Preview (copy/save/share
    /// come free there — no need to build those buttons).
    func openDraftImage() {
        guard let data = draftImage else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(linkId.uuidString).jpg")
        try? data.write(to: url, options: .atomic)
        NSWorkspace.shared.open(url)
    }

    /// Pushes the draft. Called from the popover-close event (AppDelegate wires
    /// this to StatusItemController.popoverDidClose).
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
