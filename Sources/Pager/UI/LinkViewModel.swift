import SwiftUI
import Combine
import PagerCore

/// Bridges one link's store state + engine to SwiftUI.
@MainActor
final class LinkViewModel: ObservableObject {
    @Published var text: String
    @Published var showOfflineHint = false
    @Published var detectedURLs: [TextUtil.URLMatch] = []

    let linkId: UUID
    private let store: LinkStore
    private let engine: SyncEngine?
    private var hintTask: Task<Void, Never>?
    private var suppressNextEdit = false
    private var dirty = false
    private var cancellables: Set<AnyCancellable> = []

    var onOpenSettings: (() -> Void)?
    var onClose: (() -> Void)?

    init(link: PagerLink, store: LinkStore, engine: SyncEngine?) {
        self.linkId = link.id
        self.store = store
        self.engine = engine
        self.text = link.cachedText
        self.detectedURLs = TextUtil.detectURLs(in: link.cachedText)

        // Remote updates arriving while the popover is open.
        store.$links
            .receive(on: DispatchQueue.main)
            .compactMap { $0.first(where: { $0.id == link.id })?.cachedText }
            .removeDuplicates()
            .sink { [weak self] newText in
                Task { @MainActor in
                    guard let self, newText != self.text else { return }
                    self.suppressNextEdit = true
                    self.dirty = false // remote won; nothing local left to push
                    self.text = newText
                    self.detectedURLs = TextUtil.detectURLs(in: newText)
                }
            }
            .store(in: &cancellables)

        engine?.onState = { [weak self] state in
            Task { @MainActor in self?.stateChanged(state) }
        }
        if let engine { stateChanged(engine.state) }
    }

    /// Called from the view's onChange. Updates local state only; the remote
    /// push happens in commit() when the popover closes.
    func textEdited() {
        if suppressNextEdit {
            suppressNextEdit = false
            return
        }
        if text.count > 500 { text = String(text.prefix(500)) }
        detectedURLs = TextUtil.detectURLs(in: text)
        dirty = true
        let writtenAt = Int64(Date().timeIntervalSince1970 * 1000)
        store.updateCachedText(id: linkId, text: text, writtenAt: writtenAt)
    }

    /// Pushes edited text to the server. Called when the popover closes.
    func commit() {
        guard dirty else { return }
        dirty = false
        engine?.commitText(text)
    }

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
