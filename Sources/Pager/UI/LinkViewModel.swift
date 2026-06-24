import SwiftUI
import Combine
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
        let committer: TextCommitter = engine ?? NoopCommitter()
        self.session = EditorSession(linkId: link.id, store: store, committer: committer)
        self.text = session.text
        self.detectedURLs = session.detectedURLs

        engine?.onState = { [weak self] state in
            Task { @MainActor in self?.stateChanged(state) }
        }
        if let engine { stateChanged(engine.state) }
    }

    /// Called from the view's onChange. Keeps `detectedURLs`/cap in sync with
    /// the session after it has processed the edit.
    func textEdited() {
        session.edit(text)
        if text != session.text { text = session.text } // reflect the char cap
        detectedURLs = session.detectedURLs
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
private final class NoopCommitter: TextCommitter {
    func commitText(_ text: String) {}
}
