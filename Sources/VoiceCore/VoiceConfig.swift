import Foundation

/// Client-wide constants for the voice-locket plane. Endpoints come from
/// provisioning (per circle), so unlike `PagerConfig` nothing here names a
/// backend.
public enum VoiceConfig {
    /// Protocol major version — appears in MQTT topics, HTTP paths, JSON
    /// envelopes and the binary stream header (protocol §9).
    public static let protocolVersion = 1

    /// Uplink encode settings (pendant spec §1.3): Opus, 16 kHz mono,
    /// 60 ms frames, 48 kbps.
    public static let sampleRate = 16_000
    public static let frameMs = 60
    public static let bitrate = 48_000

    /// Desktop playout thresholds (design §3.4) — the pendant's 2000/1000 ms
    /// are cellular numbers; a wired Mac can start much sooner.
    public static let playoutStartMs = 500
    public static let playoutResumeMs = 250

    /// The default july.dev voice deployment. Baked in so the add flow only
    /// asks for a claim token. Neither value is a secret: the fingerprint is
    /// a hash of the CA's *public* certificate (the same one served at
    /// `GET /v1/ca`), which is exactly cert-pinning material meant to ship in
    /// clients; the server URL is public. Only the CA's private key is
    /// secret, and that never leaves the server. Both are overridable in the
    /// add flow for other deployments and dev testbeds.
    public static let defaultServerURL = "https://vlk.liminal.flowers:8443"
    public static let defaultCAFingerprint =
        "6c4358325430c535c8d250eafe91184a8d4fe29ad6f67ee3bc433b0d1fad46a5"
}
