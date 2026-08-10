import Foundation

/// The §8 bundle as CLIENT.md specifies it. `cert`/`ca` are PEM and absent
/// in dev mode (open enrolment issues no certificates).
public struct ProvisionBundle: Decodable, Equatable {
    public var cert: String?
    public var ca: String?
    public var deviceId: String
    public var userId: String
    public var circleId: String
    public var members: [CircleMember]
    public var endpoints: Endpoints

    public struct Endpoints: Decodable, Equatable {
        public var relay: URL
        public var mqtt: Mqtt

        public struct Mqtt: Decodable, Equatable {
            public var host: String
            public var port: Int

            public init(host: String, port: Int) {
                self.host = host
                self.port = port
            }
        }

        public init(relay: URL, mqtt: Mqtt) {
            self.relay = relay
            self.mqtt = mqtt
        }
    }

    enum CodingKeys: String, CodingKey {
        case cert, ca
        case deviceId = "device_id"
        case userId = "user_id"
        case circleId = "circle_id"
        case members, endpoints
    }

    public init(cert: String?, ca: String?, deviceId: String, userId: String,
                circleId: String, members: [CircleMember], endpoints: Endpoints) {
        self.cert = cert
        self.ca = ca
        self.deviceId = deviceId
        self.userId = userId
        self.circleId = circleId
        self.members = members
        self.endpoints = endpoints
    }

    public func circleConfig(devClientCN: String? = nil) -> CircleConfig {
        CircleConfig(circleId: circleId, deviceId: deviceId, userId: userId,
                     members: members, brokerHost: endpoints.mqtt.host,
                     brokerPort: endpoints.mqtt.port, relayURL: endpoints.relay,
                     devClientCN: devClientCN)
    }
}

extension CircleMember {
    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case deviceIds = "devices"
        case name
    }
}

public enum ProvisioningError: Error, Equatable {
    case rejected(status: Int)
    case malformedResponse
}

/// How a server's TLS identity is judged, per enrolment step. First contact
/// (`GET /v1/ca`) accepts anything — the out-of-band fingerprint, not TLS, is
/// the authenticity check there. Everything after pins the fetched CA.
public enum ServerTrust: Equatable {
    case system
    case acceptAny
    case pinned([Data]) // DER anchors
}

/// The HTTP seam for enrolment: tests script it, the app uses the
/// URLSession-backed implementation below.
public protocol EnrolmentTransport: Sendable {
    func get(_ url: URL, trust: ServerTrust) async throws -> (Data, Int)
    func post(_ url: URL, json: Data, trust: ServerTrust) async throws -> (Data, Int)
}

/// The CLIENT.md credential lifecycle, minus policy (which lives in
/// `VoiceActions.enroll` — including the fingerprint gate that must run
/// between `fetchCA` and `provision`).
public struct ProvisioningClient {
    private let transport: EnrolmentTransport

    public init(transport: EnrolmentTransport = URLSessionEnrolmentTransport()) {
        self.transport = transport
    }

    /// `GET /v1/ca` — no client certificate, accept-any server trust. The
    /// caller MUST fingerprint-check the result before doing anything else.
    public func fetchCA(serverURL: URL) async throws -> String {
        let (data, status) = try await transport.get(
            serverURL.appendingPathComponent("v1/ca"), trust: .acceptAny)
        guard (200 ..< 300).contains(status) else {
            throw ProvisioningError.rejected(status: status)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Production enrolment: `{claim_token, csr}` — no device id; identity is
    /// pre-allocated to the token, the CSR's CN is a placeholder. Verified
    /// against the fetched CA only.
    public func provision(serverURL: URL, claimToken: String, csrPEM: String,
                          caAnchors: [Data]) async throws -> ProvisionBundle {
        try await post(serverURL: serverURL,
                       body: ["claim_token": claimToken, "csr": csrPEM],
                       trust: .pinned(caAnchors))
    }

    /// Dev-mode enrolment (`VLK_ENROLMENT=open`): self-picked ids, no CSR,
    /// no certificates anywhere.
    public func provisionDev(serverURL: URL, deviceId: String, circleId: String,
                             userId: String?) async throws -> ProvisionBundle {
        var body: [String: Any] = ["device_id": deviceId, "circle_id": circleId]
        if let userId { body["user_id"] = userId }
        return try await post(serverURL: serverURL, body: body, trust: .system)
    }

    private func post(serverURL: URL, body: [String: Any],
                      trust: ServerTrust) async throws -> ProvisionBundle {
        let url = serverURL.appendingPathComponent("v1/provision")
        let (data, status) = try await transport.post(
            url, json: try JSONSerialization.data(withJSONObject: body), trust: trust)
        guard (200 ..< 300).contains(status) else {
            throw ProvisioningError.rejected(status: status)
        }
        do {
            return try JSONDecoder().decode(ProvisionBundle.self, from: data)
        } catch {
            throw ProvisioningError.malformedResponse
        }
    }

    /// Mints a dev-mode device id the way pendants mint txn ids: locally,
    /// from strong randomness. Production ids are pre-allocated to the token.
    public static func mintDeviceId() -> String {
        "vpd-" + (0 ..< 4).map { _ in String(format: "%02x", UInt8.random(in: 0 ... 255)) }.joined()
    }
}

/// Real transport: one throwaway URLSession per call, its delegate enforcing
/// the requested trust policy.
public final class URLSessionEnrolmentTransport: EnrolmentTransport {
    public init() {}

    public func get(_ url: URL, trust: ServerTrust) async throws -> (Data, Int) {
        try await perform(URLRequest(url: url), trust: trust)
    }

    public func post(_ url: URL, json: Data, trust: ServerTrust) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = json
        return try await perform(request, trust: trust)
    }

    private func perform(_ request: URLRequest, trust: ServerTrust) async throws -> (Data, Int) {
        let delegate = TrustDelegate(trust: trust)
        let session = URLSession(configuration: .ephemeral, delegate: delegate,
                                 delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private final class TrustDelegate: NSObject, URLSessionDelegate {
        private let trust: ServerTrust

        init(trust: ServerTrust) {
            self.trust = trust
        }

        func urlSession(_ session: URLSession,
                        didReceive challenge: URLAuthenticationChallenge)
            async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod
                    == NSURLAuthenticationMethodServerTrust,
                  let serverTrust = challenge.protectionSpace.serverTrust else {
                return (.performDefaultHandling, nil)
            }
            switch trust {
            case .system:
                return (.performDefaultHandling, nil)
            case .acceptAny:
                // First contact: the fingerprint check that follows is the
                // authenticity gate, not this handshake.
                return (.useCredential, URLCredential(trust: serverTrust))
            case .pinned(let anchorDERs):
                let anchors = anchorDERs.compactMap {
                    SecCertificateCreateWithData(nil, $0 as CFData)
                }
                guard !anchors.isEmpty else { return (.cancelAuthenticationChallenge, nil) }
                SecTrustSetAnchorCertificates(serverTrust, anchors as CFArray)
                SecTrustSetAnchorCertificatesOnly(serverTrust, true)
                var error: CFError?
                if SecTrustEvaluateWithError(serverTrust, &error) {
                    return (.useCredential, URLCredential(trust: serverTrust))
                }
                return (.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
