import XCTest
@testable import PagerCore

final class DebugReportTests: XCTestCase {
    private func report(links: [DebugReport.LinkInfo]) -> DebugReport {
        DebugReport(appVersion: "1.0.0", build: "1", osVersion: "14.5.0",
                    deviceId: "DEVICE-1", links: links)
    }

    func testBodyOmitsCodesUnlessOptedIn() {
        let r = report(links: [
            .init(nickname: "BFF", pathPrefix: "2aaf9352", state: "connected",
                  lastWrittenAt: 17, codeDisplay: "5NDQ-WHM1-85X3-FWPQ"),
        ])
        let without = r.body(includeMessages: false)
        XCTAssertFalse(without.contains("5NDQ-WHM1-85X3-FWPQ"))
        XCTAssertTrue(without.contains("Pager version: 1.0.0 (build 1)"))
        XCTAssertTrue(without.contains("path 2aaf9352"))

        let with = r.body(includeMessages: true)
        XCTAssertTrue(with.contains("Pager codes"))
        XCTAssertTrue(with.contains("5NDQ-WHM1-85X3-FWPQ"))
    }

    func testFactoryMapsStoreAndStates() {
        let suite = "debugreport-\(UUID().uuidString)"
        let store = LinkStore(defaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let code = ShareCode(entropy: "ABCDEFGHJKMNPQ")
        let link = store.add(code: code)

        let r = DebugReportFactory.make(
            store: store, states: [link.id: "reconnecting"],
            appVersion: "1.2", build: "9", osVersion: "14.0.0")

        XCTAssertEqual(r.deviceId, store.deviceId)
        XCTAssertEqual(r.links.count, 1)
        XCTAssertEqual(r.links[0].state, "reconnecting")
        XCTAssertEqual(r.links[0].codeDisplay, code.display)
        XCTAssertEqual(r.links[0].pathPrefix, String(PagerCrypto(code: code).pathId.prefix(8)))
    }
}
