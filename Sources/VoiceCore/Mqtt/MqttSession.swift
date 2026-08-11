import Foundation
import PagerCore

/// One duplex byte pipe to the broker. The seam tests script and the app
/// backs with `NWConnection` (mTLS, TLS 1.3) — the session never knows which.
public protocol MqttByteConnection: Sendable {
    /// Bytes from the broker, ending (normally or by throw) when the
    /// connection dies.
    var incoming: AsyncThrowingStream<Data, Error> { get }
    func send(_ data: Data) async throws
    func close()
}

public protocol MqttConnector: Sendable {
    func connect() async throws -> MqttByteConnection
}

/// The signalling half of the protocol (§5.1): connects, subscribes to this
/// device's `dl` topic, keeps the connection alive, publishes to `up` at
/// QoS 1 with redelivery, and reconnects with backoff forever. Duplicate
/// deliveries are passed through — every consumer is idempotent by design.
@MainActor
public final class MqttSession {
    public enum State: Equatable {
        case connected
        case reconnecting
        case offline
    }

    /// (topic, payload) for every inbound PUBLISH, including duplicates.
    public var onMessage: ((String, Data) -> Void)?
    /// CONNACK's session-present flag, once per (re)connect. `false` means
    /// the broker forgot us: the engine must reconcile via catch-up (§5.2).
    public var onSessionPresent: ((Bool) -> Void)?
    public var onState: ((State) -> Void)?

    public private(set) var state: State = .offline {
        didSet { if state != oldValue { onState?(state) } }
    }

    private let connector: MqttConnector
    private let clientId: String
    private let subscribeTopic: String
    private let publishTopic: String
    private let keepAliveSeconds: UInt16
    private let sessionExpirySeconds: UInt32
    private let log: SyncLogSink
    private let tag: String

    private var runTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var connection: MqttByteConnection?
    private var backoff = Backoff()
    private var nextPacketId: UInt16 = 1
    /// One outbound QoS 1 publish not yet PUBACKed. `sentThisConnection`
    /// resets on reconnect; `everSent` marks true rewires (dup flag).
    private struct PendingPublish {
        let packetId: UInt16
        let payload: Data
        var sentThisConnection = false
        var everSent = false
    }

    /// In send order. Survives reconnects (resent with dup) and offline
    /// stretches (sent on connect).
    private var unacked: [PendingPublish] = []

    public init(connector: MqttConnector, clientId: String,
                subscribeTopic: String, publishTopic: String,
                keepAliveSeconds: UInt16 = 60,
                // MQTT 5 defaults the session-expiry-interval property to 0,
                // which discards the broker session at disconnect even with
                // clean_start=false — silently defeating offline delivery
                // (PROTOCOL.md §5.1). 0xFFFFFFFF = never expire, the "long
                // expiry" the protocol asks for; the persistent session is
                // what queues events for a device that was asleep.
                sessionExpirySeconds: UInt32 = 0xFFFF_FFFF,
                log: SyncLogSink = NoopSyncLog()) {
        self.connector = connector
        self.clientId = clientId
        self.subscribeTopic = subscribeTopic
        self.publishTopic = publishTopic
        self.keepAliveSeconds = keepAliveSeconds
        self.sessionExpirySeconds = sessionExpirySeconds
        self.log = log
        self.tag = clientId
    }

    private func event(_ ev: String, error: String? = nil, state: String? = nil) {
        log.log(SyncLogEvent(ev: ev, link: tag, state: state, error: error))
    }

    public func start() {
        runTask?.cancel()
        runTask = Task { await runLoop() }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        connection?.close()
        connection = nil
        state = .offline
    }

    public func reconnectNow() {
        backoff.reset()
        connection?.close() // ends `incoming`; the run loop reconnects
    }

    /// Queues a QoS 1 publish to this device's `up` topic. Delivered
    /// at-least-once: held until PUBACK, resent (dup) after a reconnect.
    public func publish(_ payload: Data) {
        unacked.append(PendingPublish(packetId: takePacketId(), payload: payload))
        Task { await sendPending() }
    }

    private func takePacketId() -> UInt16 {
        defer { nextPacketId = nextPacketId == .max ? 1 : nextPacketId + 1 }
        return nextPacketId
    }

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                try await runConnection()
            } catch is CancellationError {
                return
            } catch {
                event("mqtt.drop", error: "\(error)")
            }
            keepAliveTask?.cancel()
            keepAliveTask = nil
            connection?.close()
            connection = nil
            guard !Task.isCancelled else { return }
            state = .reconnecting
            let delay = backoff.nextDelay()
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func runConnection() async throws {
        let connection = try await connector.connect()
        self.connection = connection
        try await connection.send(MqttPacketEncoder.encode(.connect(
            clientId: clientId, keepAliveSeconds: keepAliveSeconds,
            cleanStart: false, sessionExpirySeconds: sessionExpirySeconds)))

        var decoder = MqttPacketDecoder()
        var handshaken = false
        for try await chunk in connection.incoming {
            for packet in try decoder.feed(chunk) {
                if !handshaken {
                    guard case .connack(let sessionPresent, let reason) = packet else {
                        continue // must-ignore anything unexpected pre-CONNACK
                    }
                    guard reason == 0 else {
                        throw MqttError.malformed("connack refused (\(reason))")
                    }
                    handshaken = true
                    backoff.reset()
                    state = .connected
                    event("mqtt.connack", state: sessionPresent ? "session_present" : "session_absent")
                    onSessionPresent?(sessionPresent)
                    try await connection.send(MqttPacketEncoder.encode(.subscribe(
                        packetId: takePacketId(), topic: subscribeTopic, qos: 1)))
                    markAllUnsent()
                    await sendPending()
                    startKeepAlive(over: connection)
                    continue
                }
                try await handle(packet, over: connection)
            }
        }
        // Broker closed cleanly; treat like any drop and reconnect.
        throw MqttError.malformed("connection ended")
    }

    private func handle(_ packet: MqttPacket, over connection: MqttByteConnection) async throws {
        switch packet {
        case .publish(let topic, let packetId, let payload, let qos, _):
            if qos > 0, let packetId {
                try await connection.send(MqttPacketEncoder.encode(.puback(packetId: packetId)))
            }
            onMessage?(topic, payload)
        case .puback(let packetId):
            unacked.removeAll { $0.packetId == packetId }
        case .disconnect(let reason):
            throw MqttError.malformed("server disconnect (\(reason))")
        case .pingresp, .suback:
            break
        default:
            break // must-ignore
        }
    }

    private func markAllUnsent() {
        for index in unacked.indices { unacked[index].sentThisConnection = false }
    }

    /// Sends every queued publish not yet on the wire for this connection.
    /// A resend after reconnect goes out with the dup flag, per QoS 1
    /// redelivery semantics; one queued while offline goes out fresh.
    private func sendPending() async {
        guard let connection, state == .connected else { return }
        // Re-find each time rather than iterating indices: a PUBACK arriving
        // during the awaited send may remove entries and shift the array.
        while let index = unacked.firstIndex(where: { !$0.sentThisConnection }) {
            let dup = unacked[index].everSent
            unacked[index].sentThisConnection = true
            unacked[index].everSent = true
            let entry = unacked[index]
            let packet = MqttPacket.publish(topic: publishTopic, packetId: entry.packetId,
                                            payload: entry.payload, qos: 1, dup: dup)
            try? await connection.send(MqttPacketEncoder.encode(packet))
        }
    }

    private func startKeepAlive(over connection: MqttByteConnection) {
        keepAliveTask?.cancel()
        guard keepAliveSeconds > 0 else { return }
        let interval = UInt64(keepAliveSeconds) * 1_000_000_000
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                guard let self, self.state == .connected else { return }
                try? await connection.send(MqttPacketEncoder.encode(.pingreq))
            }
        }
    }
}
