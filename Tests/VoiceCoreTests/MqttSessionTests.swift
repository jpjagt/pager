import XCTest
@testable import VoiceCore

/// A scripted broker end: records every packet the session sends, lets the
/// test push bytes down and sever the pipe.
final class ScriptedConnection: MqttByteConnection, @unchecked Sendable {
    let incoming: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var decoder = MqttPacketDecoder()
    private var recorded: [MqttPacket] = []

    init() {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        incoming = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    var sent: [MqttPacket] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(_ data: Data) async throws {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(contentsOf: (try? decoder.feed(data)) ?? [])
    }

    func push(_ packet: MqttPacket) {
        continuation.yield(MqttPacketEncoder.encode(packet))
    }

    func close() {
        continuation.finish()
    }
}

final class ScriptedConnector: MqttConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ScriptedConnection] = []

    var connectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }

    func latest() -> ScriptedConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connections.last
    }

    func connect() async throws -> MqttByteConnection {
        let connection = ScriptedConnection()
        lock.lock()
        connections.append(connection)
        lock.unlock()
        return connection
    }
}

@MainActor
final class MqttSessionTests: XCTestCase {
    private var session: MqttSession!
    private var connector: ScriptedConnector!

    override func tearDown() {
        session?.stop()
        session = nil
        super.tearDown()
    }

    private func makeSession(keepAlive: UInt16 = 0) -> MqttSession {
        connector = ScriptedConnector()
        session = MqttSession(connector: connector, clientId: "vpd-mac",
                              subscribeTopic: "v1/dev/vpd-mac/dl",
                              publishTopic: "v1/dev/vpd-mac/up",
                              keepAliveSeconds: keepAlive)
        return session
    }

    private func waitUntil(timeout: TimeInterval = 2,
                           _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// Runs the handshake up to a connected, subscribed session.
    private func handshake(sessionPresent: Bool = true) async -> ScriptedConnection {
        _ = await waitUntil { self.connector.latest()?.sent.isEmpty == false }
        let connection = connector.latest()!
        connection.push(.connack(sessionPresent: sessionPresent, reasonCode: 0))
        _ = await waitUntil {
            connection.sent.contains { if case .subscribe = $0 { return true } else { return false } }
        }
        return connection
    }

    func testHandshakeConnectsSubscribesAndReportsSessionPresent() async throws {
        let session = makeSession()
        var presents: [Bool] = []
        session.onSessionPresent = { presents.append($0) }
        session.start()

        let connection = await handshake(sessionPresent: false)
        guard case .connect(let clientId, _, let cleanStart, let expiry)? = connection.sent.first else {
            return XCTFail("first packet must be CONNECT")
        }
        XCTAssertEqual(clientId, "vpd-mac")
        XCTAssertFalse(cleanStart) // persistent session is the offline mechanism
        XCTAssertGreaterThan(expiry, 0)
        XCTAssertEqual(presents, [false])
        XCTAssertEqual(session.state, .connected)
        guard case .subscribe(_, let topic, let qos)? = connection.sent.last else {
            return XCTFail("expected SUBSCRIBE")
        }
        XCTAssertEqual(topic, "v1/dev/vpd-mac/dl")
        XCTAssertEqual(qos, 1)
    }

    func testInboundPublishIsAckedAndDelivered() async throws {
        let session = makeSession()
        var received: [(String, Data)] = []
        session.onMessage = { received.append(($0, $1)) }
        session.start()
        let connection = await handshake()

        connection.push(.publish(topic: "v1/dev/vpd-mac/dl", packetId: 42,
                                 payload: Data("{\"v\":1}".utf8), qos: 1, dup: false))
        let acked = await waitUntil {
            connection.sent.contains { $0 == .puback(packetId: 42) }
        }
        XCTAssertTrue(acked)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0, "v1/dev/vpd-mac/dl")
    }

    func testPublishQueuedOfflineSendsAfterConnectAndResendsWithDupUntilAcked() async throws {
        let session = makeSession()
        session.publish(Data("first".utf8)) // queued before any connection
        session.start()
        let first = await handshake()

        let sentOnce = await waitUntil {
            first.sent.contains {
                if case .publish(_, _, let payload, 1, false) = $0 {
                    return payload == Data("first".utf8)
                }
                return false
            }
        }
        XCTAssertTrue(sentOnce, "queued publish goes out fresh after connect")

        // No PUBACK — sever the pipe; the session reconnects and resends dup.
        first.close()
        _ = await waitUntil { self.connector.connectCount == 2 }
        let second = await handshake()
        let resent = await waitUntil {
            second.sent.contains {
                if case .publish(_, let packetId, let payload, 1, true) = $0 {
                    return payload == Data("first".utf8) && packetId != nil
                }
                return false
            }
        }
        XCTAssertTrue(resent, "unacked publish is redelivered with dup")

        // Ack it; a third connection must not carry it again.
        guard case .publish(_, let packetId?, _, _, _)? = second.sent.last else {
            return XCTFail("expected publish")
        }
        second.push(.puback(packetId: packetId))
        second.close()
        _ = await waitUntil { self.connector.connectCount == 3 }
        let third = await handshake()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(third.sent.contains {
            if case .publish = $0 { return true } else { return false }
        }, "acked publish must not be redelivered")
    }

    func testServerDisconnectTriggersReconnect() async throws {
        let session = makeSession()
        session.start()
        let connection = await handshake()
        connection.push(.disconnect(reasonCode: 0x8E)) // session taken over
        let reconnected = await waitUntil(timeout: 4) { self.connector.connectCount == 2 }
        XCTAssertTrue(reconnected)
    }

    func testKeepAlivePings() async throws {
        let session = makeSession(keepAlive: 1)
        session.start()
        let connection = await handshake()
        let pinged = await waitUntil(timeout: 3) {
            connection.sent.contains { $0 == .pingreq }
        }
        XCTAssertTrue(pinged)
    }
}
