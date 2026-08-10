import Foundation

/// The add-circle flows, extracted from the view (the `PagerActions` idiom).
/// `AddCircleView` and the e2e harness are thin shells over these.
@MainActor
public enum VoiceActions {
    public enum EnrollError: Error, Equatable {
        case emptyToken
        case badServerURL
        /// The fetched CA does not match the out-of-band fingerprint. The
        /// claim token was NOT sent — wrong server or interceptor.
        case fingerprintMismatch(expected: String, actual: String)
        case malformedCA
    }

    /// The CSR's subject CN. A placeholder by contract: the CA overrides it
    /// with the token's pre-allocated device id — a client cannot choose its
    /// own identity (CLIENT.md).
    static let placeholderCN = "voice-locket-client"

    /// Production enrolment, CLIENT.md order exactly: fetch CA (accept-any
    /// TLS) → fingerprint gate → keygen → PEM CSR → provision over
    /// CA-pinned TLS → persist bundle, re-tag the key to the granted id.
    @discardableResult
    public static func enroll(serverURL: String, claimToken: String,
                              caFingerprint: String,
                              circles: CircleStore,
                              identityStore: IdentityStoring,
                              client: ProvisioningClient = ProvisioningClient()) async throws -> VoiceCircle {
        let token = claimToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw EnrollError.emptyToken }
        let url = try parse(serverURL)

        // 1–2. First contact + the authenticity gate. On mismatch the token
        // has not left this machine and must not.
        let caPEM = try await client.fetchCA(serverURL: url)
        guard let caDER = PEM.decodeFirst(caPEM) else { throw EnrollError.malformedCA }
        guard PEM.fingerprintMatches(caFingerprint, der: caDER) else {
            throw EnrollError.fingerprintMismatch(
                expected: caFingerprint, actual: PEM.fingerprint(der: caDER))
        }

        // 3–4. Keypair under a provisional tag (the real id is the token's,
        // unknown until the server answers), CSR with the placeholder CN.
        let provisionalTag = "enrolling-\(UUID().uuidString)"
        let key = try identityStore.privateKey(deviceId: provisionalTag)
        let csrDER = try CSRBuilder.build(
            commonName: placeholderCN,
            publicKey: identityStore.publicKeyBytes(of: key),
            sign: identityStore.signer(privateKey: key))
        let csrPEM = PEM.encode(csrDER, label: "CERTIFICATE REQUEST")

        // 5. Provision, trusting only the CA fetched above.
        let bundle = try await client.provision(
            serverURL: url, claimToken: token, csrPEM: csrPEM,
            caAnchors: PEM.decodeAll(caPEM))

        // 6. Persist: certificate + re-homed key in the Keychain, CA DERs +
        // config in the store.
        guard let certPEM = bundle.cert, let certDER = PEM.decodeFirst(certPEM) else {
            throw ProvisioningError.malformedResponse
        }
        try identityStore.storeCertificate(certDER, deviceId: bundle.deviceId)
        identityStore.retagKey(fromDeviceId: provisionalTag, toDeviceId: bundle.deviceId)
        let caAnchors = bundle.ca.map(PEM.decodeAll) ?? PEM.decodeAll(caPEM)
        return circles.add(config: bundle.circleConfig(), caBundle: caAnchors)
    }

    /// Dev-mode enrolment against a `VLK_ENROLMENT=open` testbed: self-picked
    /// ids, no certificates; identity travels as `X-Client-CN` from here on.
    @discardableResult
    public static func enrollDev(serverURL: String, circleId: String,
                                 userId: String? = nil,
                                 circles: CircleStore,
                                 client: ProvisioningClient = ProvisioningClient()) async throws -> VoiceCircle {
        let url = try parse(serverURL)
        let trimmedCircle = circleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCircle.isEmpty else { throw EnrollError.emptyToken }
        let deviceId = ProvisioningClient.mintDeviceId()
        let bundle = try await client.provisionDev(
            serverURL: url, deviceId: deviceId, circleId: trimmedCircle, userId: userId)
        return circles.add(config: bundle.circleConfig(devClientCN: bundle.deviceId))
    }

    private static func parse(_ serverURL: String) throws -> URL {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.hasPrefix("http") == true else {
            throw EnrollError.badServerURL
        }
        return url
    }
}
