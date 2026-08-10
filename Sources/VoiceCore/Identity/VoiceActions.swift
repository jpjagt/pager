import Foundation

/// The add-circle flow, extracted from the view (the `PagerActions` idiom):
/// mint a device id, grow a keypair in the Keychain, build the CSR, redeem
/// the claim token, persist certificate + circle. `AddCircleView` is a thin
/// shell over this.
@MainActor
public enum VoiceActions {
    public enum EnrollError: Error, Equatable {
        case emptyToken
        case badServerURL
    }

    @discardableResult
    public static func enroll(serverURL: String, claimToken: String,
                              circles: CircleStore,
                              identityStore: KeychainIdentityStore,
                              client: ProvisioningClient = ProvisioningClient()) async throws -> VoiceCircle {
        let token = claimToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw EnrollError.emptyToken }
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.hasPrefix("http") == true else {
            throw EnrollError.badServerURL
        }

        let deviceId = ProvisioningClient.mintDeviceId()
        let key = try identityStore.privateKey(deviceId: deviceId)
        let csr = try CSRBuilder.build(
            commonName: deviceId,
            publicKey: identityStore.publicKeyBytes(of: key),
            sign: identityStore.signer(privateKey: key))
        let response = try await client.provision(
            serverURL: url, claimToken: token, requestedDeviceId: deviceId, csr: csr)
        // The CA may grant a different id than requested (§4: the server has
        // final say at issuance). The certificate is labeled with the granted
        // id; the Keychain forms the SecIdentity by matching the cert's
        // public key to the private key, so the key's tag doesn't matter.
        try identityStore.storeCertificate(response.certificate, deviceId: response.deviceId)
        return circles.add(config: response.circleConfig(), caBundle: response.caBundle)
    }
}
