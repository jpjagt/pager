import Foundation

/// What `POST /v1/provision` returns, as this client assumes it. The
/// protocol (§8) specifies the *contents* — certificate, CA bundle,
/// endpoints, circle config — but not the JSON shape; this is the shape the
/// reference server should implement (flagged in the design doc's open
/// questions). Certificates travel as base64 DER.
public struct ProvisionResponse: Decodable, Equatable {
    public var deviceId: String
    public var userId: String
    public var certificate: Data
    public var caBundle: [Data]
    public var circleId: String
    public var members: [CircleMember]
    public var brokerHost: String
    public var brokerPort: Int
    public var relayURL: URL

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case userId = "user_id"
        case certificate
        case caBundle = "ca_bundle"
        case circleId = "circle_id"
        case members
        case brokerHost = "broker_host"
        case brokerPort = "broker_port"
        case relayURL = "relay_url"
    }

    public func circleConfig() -> CircleConfig {
        CircleConfig(circleId: circleId, deviceId: deviceId, userId: userId,
                     members: members, brokerHost: brokerHost,
                     brokerPort: brokerPort, relayURL: relayURL)
    }
}

extension CircleMember {
    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case deviceIds = "device_ids"
        case name
    }
}

public enum ProvisioningError: Error, Equatable {
    case rejected(status: Int)
    case malformedResponse
}

/// One round-trip: claim token + CSR in, certificate + circle config out.
/// The HTTP call is a seam (plain closure) — tests script it, the app and
/// e2e pass a URLSession-backed one. This is the sole *unauthenticated*
/// request in the system: the device has no certificate yet, the claim
/// token is what authorizes the enrolment.
public struct ProvisioningClient {
    public typealias Post = (URL, Data) async throws -> (Data, Int)

    private let post: Post

    public init(post: @escaping Post) {
        self.post = post
    }

    public init(session: URLSession = .shared) {
        self.init { url, body in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    public func provision(serverURL: URL, claimToken: String,
                          requestedDeviceId: String, csr: Data) async throws -> ProvisionResponse {
        let body: [String: Any] = [
            "claim_token": claimToken,
            "device_id": requestedDeviceId,
            "csr": csr.base64EncodedString(),
        ]
        let url = serverURL.appendingPathComponent("v1/provision")
        let (data, status) = try await post(url, try JSONSerialization.data(withJSONObject: body))
        guard (200 ..< 300).contains(status) else {
            throw ProvisioningError.rejected(status: status)
        }
        do {
            return try JSONDecoder().decode(ProvisionResponse.self, from: data)
        } catch {
            throw ProvisioningError.malformedResponse
        }
    }

    /// Mints a requested device id the way pendants mint txn ids: locally,
    /// from strong randomness, no server round-trip (protocol §4 gives the
    /// server final say at issuance).
    public static func mintDeviceId() -> String {
        "vpd-" + (0 ..< 4).map { _ in String(format: "%02x", UInt8.random(in: 0 ... 255)) }.joined()
    }
}
