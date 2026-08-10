import XCTest
@testable import VoiceCore

final class VoiceConfigTests: XCTestCase {
    func testDesktopPlayoutThresholdsAreBelowPendantDefaults() {
        XCTAssertLessThan(VoiceConfig.playoutStartMs, 2000)
        XCTAssertLessThan(VoiceConfig.playoutResumeMs, VoiceConfig.playoutStartMs)
    }
}
