import Foundation
import VoiceCore

/// Live voice-locket flows against a real server — the §3.3 reference-client
/// job. Gated on environment because the voice server may not exist where
/// `swift run e2e` runs for pager changes:
///
///   VOICE_SERVER_URL      base URL of the provisioning/relay server
///   VOICE_CLAIM_TOKEN_A   claim token for device A (user A)
///   VOICE_CLAIM_TOKEN_B   claim token for device B (user B, same circle)
///
/// Unset → the stage prints one skip line and passes.
@MainActor
enum VoiceFlows {
    /// Headless audio: capture synthesizes sine frames at frame cadence;
    /// playback drives the engine's pull with its own clock. What the app's
    /// AVAudioIO does with hardware, this does with math.
    @MainActor
    final class SyntheticAudioIO: AudioIO {
        private var captureTask: Task<Void, Never>?
        private var playbackTask: Task<Void, Never>?
        private(set) var framesRendered = 0

        func startCapture(onFrame: @escaping ([Int16]) -> Void) throws {
            var phase = 0.0
            captureTask = Task { @MainActor in
                while !Task.isCancelled {
                    let frame = (0 ..< 960).map { i -> Int16 in
                        Int16(6000 * sin(phase + 2 * .pi * 440 * Double(i) / 16000))
                    }
                    phase += 2 * .pi * 440 * 960 / 16000
                    onFrame(frame)
                    try? await Task.sleep(nanoseconds: 60_000_000)
                }
            }
        }

        func stopCapture() {
            captureTask?.cancel()
            captureTask = nil
        }

        func startPlayback(next: @escaping () -> [Int16]?) throws {
            playbackTask = Task { @MainActor in
                while !Task.isCancelled {
                    if next() != nil { framesRendered += 1 }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            }
        }

        func stopPlayback() {
            playbackTask?.cancel()
            playbackTask = nil
        }
    }

    /// One headless voice device: isolated stores + Keychain namespace,
    /// wired exactly like `VoiceCoordinator` minus the status item.
    @MainActor
    final class VoiceDevice {
        let circles: CircleStore
        let messages: MessageStore
        let identityStore: KeychainIdentityStore
        let audio = SyntheticAudioIO()
        var engine: VoiceEngine?
        private let suiteName: String
        private let storeDir: URL

        init(name: String) {
            suiteName = "e2e-voice-\(name)-\(UUID().uuidString)"
            storeDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(suiteName)
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            circles = CircleStore(defaults: defaults)
            messages = MessageStore(baseURL: storeDir)
            identityStore = KeychainIdentityStore(tagPrefix: "dev.july.pager.voice.e2e")
        }

        func join(serverURL: String, claimToken: String) async throws -> VoiceCircle {
            let circle = try await VoiceActions.enroll(
                serverURL: serverURL, claimToken: claimToken,
                circles: circles, identityStore: identityStore)
            let config = circle.config
            let identity: @Sendable () -> SecIdentity? = { [identityStore] in
                identityStore.identity(deviceId: config.deviceId)
            }
            let anchors = circle.caBundle.compactMap {
                SecCertificateCreateWithData(nil, $0 as CFData)
            }
            let mqtt = MqttSession(
                connector: NWMqttConnector(host: config.brokerHost,
                                           port: UInt16(config.brokerPort),
                                           identity: identity,
                                           caCertificates: { anchors }),
                clientId: config.deviceId,
                subscribeTopic: "v1/dev/\(config.deviceId)/dl",
                publishTopic: "v1/dev/\(config.deviceId)/up")
            let relay = RelayClient(baseURL: config.relayURL,
                                    identity: identity, anchors: { anchors })
            engine = VoiceEngine(
                circleId: circle.id, config: config, signal: mqtt, transport: relay,
                codec: try LibOpusCodec(), audio: audio, messages: messages,
                circles: circles)
            engine?.start()
            return circle
        }

        func teardown() {
            engine?.stop()
            if let circle = circles.circles.first {
                identityStore.removeIdentity(deviceId: circle.config.deviceId)
            }
            try? FileManager.default.removeItem(at: storeDir)
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
    }

    static func run(check: (String, Bool) -> Void) async {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["VOICE_SERVER_URL"],
              let tokenA = env["VOICE_CLAIM_TOKEN_A"],
              let tokenB = env["VOICE_CLAIM_TOKEN_B"] else {
            print("  · skipped — set VOICE_SERVER_URL, VOICE_CLAIM_TOKEN_A, "
                + "VOICE_CLAIM_TOKEN_B to run the voice stage")
            return
        }

        let a = VoiceDevice(name: "A")
        let b = VoiceDevice(name: "B")
        defer {
            a.teardown()
            b.teardown()
        }

        do {
            let circleA = try await a.join(serverURL: server, claimToken: tokenA)
            let circleB = try await b.join(serverURL: server, claimToken: tokenB)
            check("both devices provision into one circle",
                  circleA.config.circleId == circleB.config.circleId)
        } catch {
            check("provisioning succeeds (\(error))", false)
            return
        }

        // A speaks ~1.5 s; release sends the end-of-message.
        a.engine?.recordPressed()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        a.engine?.recordReleased()
        check("A's upload completes",
              await E2E.waitUntil(15) { a.engine?.isRecording == false })

        // B is notified over MQTT, eagerly downloads, queues it unheard.
        check("B receives and stores the transmission",
              await E2E.waitUntil(30) { b.engine?.unheardCount == 1 })

        // B taps: plays, marks heard, emits the heard receipt.
        b.engine?.playTapped()
        check("B plays the message to completion",
              await E2E.waitUntil(30) {
                  b.messages.index(circleId: b.circles.circles[0].id)
                      .allSatisfy(\.heard) && b.engine?.unheardCount == 0
              })
        check("B actually rendered audio frames", b.audio.framesRendered > 10)

        // B replies; A receives — the conversational round-trip.
        b.engine?.recordPressed()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        b.engine?.recordReleased()
        check("A receives B's reply",
              await E2E.waitUntil(30) { a.engine?.unheardCount == 1 })
        a.engine?.playTapped()
        check("A hears the reply",
              await E2E.waitUntil(30) { a.engine?.unheardCount == 0 })
    }
}
