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
    /// One window + one view model per link, alive only while the window is
    /// open. Both are torn down in the window's close callback.
    private var windows: [UUID: PagerWindow] = [:]
    private var models: [UUID: LinkViewModel] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var appearanceObserver: NSKeyValueObservation?
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

        // The menu bar ink is a resolved color picked for the current
        // appearance (see `StatusItemController.ink`), so light/dark has to
        // re-render it — nothing else would.
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.renderAll() }
        }

        if store.links.isEmpty {
            showOnboarding()
        }

        if ProcessInfo.processInfo.environment["PAGER_DEBUG_WINDOW"] == "1" {
            DispatchQueue.main.async { [weak self] in self?.openDebugWindow() }
        }
    }

    /// Tier-2 verification hook from the reskin design doc: open the first
    /// link's window straight away and print the **visible device** rect, so a
    /// real-app render can be grabbed with `screencapture -R x,y,w,h`. The
    /// printed rect is in screencapture's coordinate space (origin top-left of
    /// the main display), not AppKit's bottom-left one.
    private func openDebugWindow() {
        guard let link = store.links.first, let window = openWindow(for: link.id) else { return }
        // A run-loop timer, not a main-queue hop: unbundled (`swift run Pager`)
        // Sparkle can't start and puts up a modal alert, and the main dispatch
        // queue does not re-enter while a modal loop is on the stack — the
        // frame would never be printed on exactly the runs this hook is for.
        let timer = Timer(timeInterval: 0.4, repeats: false) { _ in
            MainActor.assumeIsolated {
                let rect = window.visibleDeviceFrame
                let screenHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
                print("PAGER_FRAME \(Int(rect.minX)),\(Int(screenHeight - rect.maxY))," +
                      "\(Int(rect.width)),\(Int(rect.height))")
                fflush(stdout)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
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
            closeWindow(for: id)
            controllers[id] = nil
            engines[id] = nil
        }
        for link in links where controllers[link.id] == nil { addController(for: link) }
        render(links: links)
        updatePlaceholder(visible: links.isEmpty)
        if links.isEmpty { showOnboarding() }
    }

    private func render(links: [PagerLink]) {
        for link in links {
            controllers[link.id]?.render(content: store.cachedContent(id: link.id),
                                         prefs: link.appearance)
        }
    }

    /// Repaints every menu bar item. Needed on a system appearance flip: the
    /// ink is a color resolved for one appearance, so nothing else would.
    private func renderAll() { render(links: store.links) }

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
        controller.onClick = { [weak self] in self?.toggleWindow(for: linkId) }
        controller.onDropPayload = { [weak self] payload in
            self?.handleDrop(payload, linkId: linkId)
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

    /// Drop on the menu bar item = edit + commit in one step. Dropping on the
    /// shared line is deliberately "send this" — no popover, no draft.
    private func handleDrop(_ payload: DropPayload, linkId: UUID) {
        guard let engine = engines[linkId] else { NSSound.beep(); return }
        let session = EditorSession(linkId: linkId, store: store, committer: engine)
        switch payload {
        case .image(let raw):
            do { try session.setImage(raw) } catch { NSSound.beep(); return }
        case .text(let text):
            session.edit(text)
        }
        session.commit()
    }

    func engine(for id: UUID) -> SyncEngine? { engines[id] }

    // MARK: - Pager windows

    /// Menu bar click. A focused window is the user saying "done" (commit and
    /// close); a visible-but-unfocused one just needs raising — closing a
    /// window the user can see but isn't focused on feels broken.
    private func toggleWindow(for linkId: UUID) {
        guard let window = windows[linkId], window.isVisible else {
            openWindow(for: linkId)
            return
        }
        if window.isKeyWindow {
            models[linkId]?.commit()
            closeWindow(for: linkId)
        } else {
            NSApp.activateForWindow()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    @discardableResult
    private func openWindow(for linkId: UUID) -> PagerWindow? {
        if let existing = windows[linkId] {
            NSApp.activateForWindow()
            existing.makeKeyAndOrderFront(nil)
            return existing
        }
        guard let link = store.links.first(where: { $0.id == linkId }) else { return nil }

        let model = LinkViewModel(link: link, store: store, engine: engines[linkId])
        model.onRequestClose = { [weak self] in self?.closeWindow(for: linkId) }
        model.onOpenMenu = { [weak self] in self?.showPagerMenu() }

        let updates = updateController
        let window = PagerWindow(linkId: linkId) { focus in
            PagerDeviceAdapter(model: model, updates: updates, focus: focus)
        }
        window.onFrameChanged = { [weak self] rect in
            self?.persistWindowFrame(rect, linkId: linkId)
        }
        window.onClosed = { [weak self] in
            self?.models[linkId]?.removePasteMonitor()
            self?.models[linkId] = nil
            self?.windows[linkId] = nil
        }

        windows[linkId] = window
        models[linkId] = model
        window.show(persistedVisibleFrame: link.windowFrame,
                    avoiding: occupiedFrames(excluding: linkId))
        model.installPasteMonitor()
        return window
    }

    private func closeWindow(for linkId: UUID) {
        windows[linkId]?.close() // onClosed does the teardown
    }

    /// The visible rects of the other open pagers, so a new one doesn't land on
    /// top of them.
    private func occupiedFrames(excluding linkId: UUID) -> [CGRect] {
        windows.compactMap { id, window in
            id == linkId || !window.isVisible ? nil : window.visibleDeviceFrame
        }
    }

    /// Debounced by `PagerWindow`; this is the end of a drag.
    private func persistWindowFrame(_ rect: CGRect, linkId: UUID) {
        guard var link = store.links.first(where: { $0.id == linkId }),
              link.windowFrame != rect else { return }
        link.windowFrame = rect
        store.update(link)
    }

    /// The `···` key: the menu the popover used to carry in its header.
    private func showPagerMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "settings…", action: #selector(openSettingsFromMenu), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "quit pager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func openSettingsFromMenu() {
        showSettings()
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
        NSApp.activateForWindow()
        let alert = NSAlert()
        alert.messageText = "Pager is not configured"
        alert.informativeText = "Set the Firebase database URL in PagerConfig.swift (see docs/firebase-setup.md)."
        alert.runModal()
    }
}
