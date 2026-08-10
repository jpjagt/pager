import AppKit
import Combine
import Security
import PagerCore
import VoiceCore

/// The voice half of the app shell: one `VoiceEngine` + one status item +
/// one hotkey per circle, reconciled against `CircleStore` exactly the way
/// `AppDelegate` reconciles pager links. Holds no decisions — construction
/// and forwarding only.
@MainActor
final class VoiceCoordinator {
    let circles = CircleStore()
    let identityStore = KeychainIdentityStore()
    private let messages = MessageStore()
    private let hotkeys = HotkeyCenter()
    private let log: SyncLogSink
    private let showSettings: () -> Void

    private var engines: [UUID: VoiceEngine] = [:]
    private var controllers: [UUID: CircleStatusItemController] = [:]
    private var hotkeyTokens: [UUID: UInt32] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(log: SyncLogSink, showSettings: @escaping () -> Void) {
        self.log = log
        self.showSettings = showSettings
    }

    func start() {
        circles.$circles
            .receive(on: DispatchQueue.main)
            .sink { [weak self] list in
                Task { @MainActor in self?.reconcile(list) }
            }
            .store(in: &cancellables)
    }

    func reconnectAll() {
        engines.values.forEach { $0.reconnectNow() }
    }

    func flushAll() {
        engines.values.forEach { $0.flushSynchronously() }
    }

    // MARK: - Reconcile

    private func reconcile(_ list: [VoiceCircle]) {
        let current = Set(list.map(\.id))
        for (id, controller) in controllers where !current.contains(id) {
            controller.removeFromStatusBar()
            engines[id]?.stop()
            controllers[id] = nil
            engines[id] = nil
        }
        for circle in list where controllers[circle.id] == nil {
            addCircle(circle)
        }
        rebindHotkeys(list)
    }

    private func addCircle(_ circle: VoiceCircle) {
        let config = circle.config
        let identity: @Sendable () -> SecIdentity? = { [identityStore] in
            identityStore.identity(deviceId: config.deviceId)
        }
        let anchors = circle.caBundle.compactMap {
            SecCertificateCreateWithData(nil, $0 as CFData)
        }
        let anchorsProvider: @Sendable () -> [SecCertificate] = { anchors }

        let connector = NWMqttConnector(
            host: config.brokerHost, port: UInt16(config.brokerPort),
            identity: identity, caCertificates: anchorsProvider,
            plaintext: config.devClientCN != nil)
        let mqtt = MqttSession(
            connector: connector, clientId: config.deviceId,
            subscribeTopic: "v1/dev/\(config.deviceId)/dl",
            publishTopic: "v1/dev/\(config.deviceId)/up",
            log: log)
        let relay = RelayClient(baseURL: config.relayURL,
                                identity: identity, anchors: anchorsProvider,
                                devClientCN: config.devClientCN)
        guard let codec = try? LibOpusCodec() else { return }
        let engine = VoiceEngine(
            circleId: circle.id, config: config, signal: mqtt, transport: relay,
            codec: codec, audio: AVAudioIO(), messages: messages, circles: circles,
            log: log)

        let controller = CircleStatusItemController(circleId: circle.id)
        let circleId = circle.id
        controller.onPlay = { [weak engine] in engine?.playTapped() }
        controller.onRecordToggle = { [weak engine] in
            guard let engine else { return }
            engine.isRecording ? engine.recordReleased() : engine.recordPressed()
        }
        controller.onDiscard = { [weak engine] in engine?.recordDiscarded() }
        controller.onUnlink = { [weak self] in self?.confirmUnlink(circleId) }
        controller.onSettings = { [weak self] in self?.showSettings() }
        controller.menuState = { [weak self, weak engine] in
            let circle = self?.circles.circles.first { $0.id == circleId }
            return (nickname: circle?.nickname ?? "locket",
                    unheard: engine?.unheardCount ?? 0,
                    playing: engine?.isPlaying ?? false,
                    recording: engine?.isRecording ?? false,
                    shortcut: circle?.shortcut)
        }
        engine.onLed = { [weak controller] led in controller?.render(led) }

        engines[circle.id] = engine
        controllers[circle.id] = controller
        engine.start()
    }

    private func rebindHotkeys(_ list: [VoiceCircle]) {
        for (_, token) in hotkeyTokens { hotkeys.unregister(token) }
        hotkeyTokens = [:]
        for circle in list {
            guard let binding = circle.shortcut, let engine = engines[circle.id] else { continue }
            let token = hotkeys.register(binding, handlers: HotkeyCenter.Handlers(
                onTap: { [weak engine] in engine?.playTapped() },
                onHoldBegan: { [weak engine] in engine?.recordPressed() },
                onHoldEnded: { [weak engine] in engine?.recordReleased() }))
            if let token { hotkeyTokens[circle.id] = token }
        }
    }

    // MARK: - Unlink

    private func confirmUnlink(_ circleId: UUID) {
        guard let circle = circles.circles.first(where: { $0.id == circleId }) else { return }
        NSApp.activateForWindow()
        let alert = NSAlert()
        alert.messageText = "unlink \(circle.nickname)?"
        alert.informativeText = "this removes the locket, its identity and its stored "
            + "messages from this Mac only. your other devices keep theirs."
        alert.addButton(withTitle: "unlink")
        alert.addButton(withTitle: "cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        unlink(circleId)
    }

    func unlink(_ circleId: UUID) {
        guard let circle = circles.circles.first(where: { $0.id == circleId }) else { return }
        engines[circleId]?.stop()
        identityStore.removeIdentity(deviceId: circle.config.deviceId)
        messages.removeCircle(circleId: circleId)
        circles.remove(id: circleId) // reconcile tears down the rest
    }

    // MARK: - Add flow

    private lazy var addCircleWindow = WindowHost<AddCircleView>(
        title: "Pager", size: NSSize(width: 420, height: 300))

    func showAddCircle() {
        addCircleWindow.show(AddCircleView(
            circles: circles,
            identityStore: identityStore,
            onDone: { [weak self] in self?.addCircleWindow.close() }))
    }
}
