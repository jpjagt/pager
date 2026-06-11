import AppKit
import Combine
import Network
import SwiftUI
import PagerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = LinkStore()
    private var controllers: [UUID: StatusItemController] = [:]
    private var engines: [UUID: SyncEngine] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private let pathMonitor = NWPathMonitor()
    private var transport: SyncTransport?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = PagerConfig.databaseURL {
            transport = FirebaseClient(baseURL: url)
        } else {
            showConfigAlert()
        }

        store.$links
            .receive(on: DispatchQueue.main)
            .sink { [weak self] links in
                Task { @MainActor in self?.reconcile(links: links) }
            }
            .store(in: &cancellables)

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied, let self else { return }
            Task { @MainActor in self.reconnectAll() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "pager.pathmonitor"))

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        if store.links.isEmpty {
            showOnboarding()
        }
    }

    @objc private func didWake() {
        reconnectAll()
    }

    private func reconnectAll() {
        engines.values.forEach { $0.reconnectNow() }
    }

    /// Diff current links against live controllers/engines.
    private func reconcile(links: [PagerLink]) {
        let current = Set(links.map(\.id))
        for (id, controller) in controllers where !current.contains(id) {
            controller.removeFromStatusBar()
            engines[id]?.stop()
            controllers[id] = nil
            engines[id] = nil
        }
        for link in links {
            if controllers[link.id] == nil { addController(for: link) }
            controllers[link.id]?.render(text: link.cachedText, prefs: link.appearance)
        }
    }

    private func addController(for link: PagerLink) {
        let controller = StatusItemController(linkId: link.id)
        controllers[link.id] = controller
        let linkId = link.id
        controller.makePopoverContent = { [weak self] in
            self?.popoverContent(for: linkId) ?? NSViewController()
        }
        guard let transport else { return }
        let crypto = PagerCrypto(code: link.shareCode)
        let engine = SyncEngine(
            transport: transport, crypto: crypto,
            pathId: crypto.pathId, deviceId: store.deviceId)
        engine.onText = { [weak self] text, writtenAt in
            self?.store.updateCachedText(id: linkId, text: text, writtenAt: writtenAt)
        }
        engines[link.id] = engine
        engine.start()
    }

    func engine(for id: UUID) -> SyncEngine? { engines[id] }

    /// Replaced with the real popover in Task 13.
    func popoverContent(for linkId: UUID) -> NSViewController {
        NSViewController()
    }

    /// Replaced with the real onboarding in Task 14.
    func showOnboarding() {}

    /// Replaced with the real settings window in Task 15.
    func showSettings() {}

    private func showConfigAlert() {
        let alert = NSAlert()
        alert.messageText = "Pager is not configured"
        alert.informativeText = "Set the Firebase database URL in PagerConfig.swift (see docs/firebase-setup.md)."
        alert.runModal()
    }
}
