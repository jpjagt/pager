import XCTest
@testable import VoiceCore

/// Live enrolment against a real server — a debugging/verification harness,
/// not part of the normal suite. Skips unless env is set:
///
///   VOICE_LIVE_URL=https://host:8443 VOICE_LIVE_FP=<ca sha256> \
///   VOICE_LIVE_TOKEN=<claim token> swift test --filter LiveEnrollTests
///
/// Prints the exact error the add flow would swallow into generic copy.
@MainActor
final class LiveEnrollTests: XCTestCase {
    func testLiveEnroll() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["VOICE_LIVE_URL"], let fp = env["VOICE_LIVE_FP"],
              let token = env["VOICE_LIVE_TOKEN"] else {
            throw XCTSkip("VOICE_LIVE_URL/FP/TOKEN not set")
        }
        let suiteName = "live-enroll-\(UUID().uuidString)"
        let circles = CircleStore(defaults: UserDefaults(suiteName: suiteName)!)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let identityStore = KeychainIdentityStore(tagPrefix: "dev.july.pager.voice.livetest")
        do {
            let circle = try await VoiceActions.enroll(
                serverURL: url, claimToken: token, caFingerprint: fp,
                circles: circles, identityStore: identityStore)
            print("LIVE-ENROLL OK: device=\(circle.config.deviceId)",
                  "circle=\(circle.config.circleId)",
                  "relay=\(circle.config.relayURL)",
                  "mqtt=\(circle.config.brokerHost):\(circle.config.brokerPort)",
                  "members=\(circle.config.members)")
            identityStore.removeIdentity(deviceId: circle.config.deviceId)
        } catch {
            XCTFail("LIVE-ENROLL ERROR: \(error)")
        }
    }
}
