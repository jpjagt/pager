import Foundation
import Network

/// The real broker pipe: TCP + TLS 1.3 (resumption comes with the OS stack)
/// with the device certificate as client identity, and the circle's private
/// CA as the only trust anchor. Deliberately thin — every decision lives in
/// `MqttSession`; unit tests never touch this file (e2e does).
public final class NWMqttConnector: MqttConnector {
    private let host: String
    private let port: UInt16
    private let identity: @Sendable () -> SecIdentity?
    private let caCertificates: @Sendable () -> [SecCertificate]
    /// Dev mode (CLIENT.md): the open-enrolment testbed's broker runs
    /// plaintext with no credentials. Never true in production.
    private let plaintext: Bool

    public init(host: String, port: UInt16,
                identity: @escaping @Sendable () -> SecIdentity?,
                caCertificates: @escaping @Sendable () -> [SecCertificate] = { [] },
                plaintext: Bool = false) {
        self.host = host
        self.port = port
        self.identity = identity
        self.caCertificates = caCertificates
        self.plaintext = plaintext
    }

    public func connect() async throws -> MqttByteConnection {
        if plaintext {
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? 1883,
                using: .tcp)
            return try await NWByteConnection.open(connection)
        }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        if let identity = identity(), let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(options, secIdentity)
        }
        let anchors = caCertificates()
        if !anchors.isEmpty {
            sec_protocol_options_set_verify_block(options, { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                SecTrustSetAnchorCertificates(trust, anchors as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, true)
                var error: CFError?
                complete(SecTrustEvaluateWithError(trust, &error))
            }, DispatchQueue.global())
        }
        let parameters = NWParameters(tls: tls)
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 8883,
            using: parameters)
        return try await NWByteConnection.open(connection)
    }
}

/// A once-only latch, safe across queues.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    /// True exactly once.
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

final class NWByteConnection: MqttByteConnection, @unchecked Sendable {
    let incoming: AsyncThrowingStream<Data, Error>
    private let connection: NWConnection

    private init(connection: NWConnection,
                 incoming: AsyncThrowingStream<Data, Error>) {
        self.connection = connection
        self.incoming = incoming
    }

    static func open(_ connection: NWConnection) async throws -> NWByteConnection {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // The state handler can fire on the connection queue after the
            // first terminal state; resume exactly once.
            let resumed = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.take() { cont.resume() }
                case .failed(let error):
                    if resumed.take() { cont.resume(throwing: error) }
                case .cancelled:
                    if resumed.take() { cont.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "voice.mqtt"))
        }

        let stream = AsyncThrowingStream<Data, Error> { continuation in
            func receive() {
                connection.receive(minimumIncompleteLength: 1,
                                   maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let data, !data.isEmpty { continuation.yield(data) }
                    if let error {
                        continuation.finish(throwing: error)
                    } else if isComplete {
                        continuation.finish()
                    } else {
                        receive()
                    }
                }
            }
            receive()
            continuation.onTermination = { _ in connection.cancel() }
        }
        return NWByteConnection(connection: connection, incoming: stream)
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    func close() {
        connection.cancel()
    }
}
