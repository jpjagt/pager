import AppKit
import Combine
import Network
import SwiftUI
import PagerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = LinkStore()
    private var placeholderItem: NSStatusItem?
    private var controllers: [UUID: StatusItemController] = [:]
    private var engines: [UUID: SyncEngine] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private let pathMonitor = NWPathMonitor()
    private var transport: SyncTransport?
    private let syncLog = FileSyncLog(url: AppDelegate.logURL)
    private let mailComposer: MailComposer = SharingServiceMailComposer()
    let updateController = UpdateController()

    /// ~/Library/Logs/Pager/pager-logs.jsonl — also visible in Console.app.
    static let logURL: URL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Pager/pager-logs.jsonl")

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

    /// Clicking the app in Finder/Dock-less reopen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if store.links.isEmpty { showOnboarding() }
        return true
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
        updatePlaceholder(visible: links.isEmpty)
        if links.isEmpty { showOnboarding() }
    }

    /// A single 📟 status item shown while no pagers are configured, so the
    /// app stays reachable from the menu bar.
    private func updatePlaceholder(visible: Bool) {
        if visible {
            guard placeholderItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = "📟"
            item.button?.target = self
            item.button?.action = #selector(placeholderClicked)
            placeholderItem = item
        } else if let item = placeholderItem {
            NSStatusBar.system.removeStatusItem(item)
            placeholderItem = nil
        }
    }

    @objc private func placeholderClicked() {
        showOnboarding()
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
            pathId: crypto.pathId, deviceId: store.deviceId, log: syncLog)
        engine.onContent = { [weak self] content, writtenAt in
            self?.store.updateCachedContent(id: linkId, content: content, writtenAt: writtenAt)
        }
        engines[link.id] = engine
        engine.start()
    }

    func engine(for id: UUID) -> SyncEngine? { engines[id] }

    func popoverContent(for linkId: UUID) -> NSViewController {
        guard let link = store.links.first(where: { $0.id == linkId }) else {
            return NSViewController()
        }
        let model = LinkViewModel(link: link, store: store, engine: engines[linkId])
        model.onClose = { [weak self] in self?.controllers[linkId]?.closePopover() }
        model.onOpenSettings = { [weak self] in self?.showSettings() }
        // Commit the draft when the popover actually closes (any dismissal path).
        controllers[linkId]?.onClose = { [weak model] in model?.commit() }
        return NSHostingController(rootView: PopoverView(model: model, updates: updateController))
    }

    private lazy var addPagerWindow = WindowHost<AddPagerView>(
        title: "Pager", size: NSSize(width: 420, height: 320))

    func showOnboarding() {
        addPagerWindow.show(AddPagerView(
            isOnboarding: store.links.isEmpty,
            store: store,
            transport: transport,
            updates: updateController,
            onDone: { [weak self] in self?.addPagerWindow.close() }))
    }

    private lazy var settingsWindow = WindowHost<SettingsView>(
        title: "Pager Settings", size: NSSize(width: 440, height: 420), autoSize: true)

    func showSettings() {
        settingsWindow.show(SettingsView(
            store: store,
            updates: updateController,
            onAddPager: { [weak self] in self?.showOnboarding() },
            onEmailDebugReport: { [weak self] includeMessages in
                self?.sendDebugReport(includeMessages: includeMessages) ?? false
            }))
    }

    /// Composes a debug email (recipient/subject/body + log attachment) and
    /// hands it to the user's mail client. Returns false if no mail account is
    /// configured, so the UI can explain why nothing happened.
    @discardableResult
    func sendDebugReport(includeMessages: Bool) -> Bool {
        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let report = DebugReportFactory.make(
            store: store,
            states: engines.mapValues { "\($0.state)" },
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?",
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")

        let logExists = FileManager.default.fileExists(atPath: AppDelegate.logURL.path)
        let mail = ComposedMail(
            recipient: PagerConfig.supportEmail,
            subject: report.subject,
            body: report.body(includeMessages: includeMessages),
            attachment: logExists ? AppDelegate.logURL : nil)
        return mailComposer.compose(mail)
    }

    private func showConfigAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Pager is not configured"
        alert.informativeText = "Set the Firebase database URL in PagerConfig.swift (see docs/firebase-setup.md)."
        alert.runModal()
    }
}
