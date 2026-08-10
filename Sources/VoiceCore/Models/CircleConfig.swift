import Foundation

/// One member of a circle: a user and the devices that act for them.
/// Circles are groups of *users* (protocol §2); the device list is what lets
/// a client resolve an echoed `receipt.patch` (annotated with `device_id`)
/// to the user whose state changed.
public struct CircleMember: Codable, Equatable {
    public var userId: String
    public var deviceIds: [String]
    public var name: String?

    public init(userId: String, deviceIds: [String], name: String? = nil) {
        self.userId = userId
        self.deviceIds = deviceIds
        self.name = name
    }
}

/// Everything provisioning hands back that the client needs to operate,
/// minus the certificate itself (which lives in the Keychain).
public struct CircleConfig: Codable, Equatable {
    public var circleId: String
    /// This client's own device identity (`vpd-…`), from the certificate CN.
    public var deviceId: String
    /// The user this device acts for (`usr-…`).
    public var userId: String
    public var members: [CircleMember]
    /// MQTT broker, e.g. host:8883.
    public var brokerHost: String
    public var brokerPort: Int
    /// HTTPS relay base URL for §5.2 endpoints.
    public var relayURL: URL

    public init(circleId: String, deviceId: String, userId: String,
                members: [CircleMember], brokerHost: String, brokerPort: Int = 8883,
                relayURL: URL) {
        self.circleId = circleId
        self.deviceId = deviceId
        self.userId = userId
        self.members = members
        self.brokerHost = brokerHost
        self.brokerPort = brokerPort
        self.relayURL = relayURL
    }

    /// The same-user predicate behind user-scoped receipts (§7.2): the wire
    /// annotates patches with a device id, and the member list is the only
    /// map from devices to users. Unknown devices resolve to nil — callers
    /// must treat that as "not my user", never crash.
    public func userId(forDevice deviceId: String) -> String? {
        if deviceId == self.deviceId { return userId }
        return members.first { $0.deviceIds.contains(deviceId) }?.userId
    }
}
