import XCTest
@testable import VoiceCore

final class CircleStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "voice-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func config(_ n: Int) -> CircleConfig {
        CircleConfig(circleId: "cir-\(n)", deviceId: "vpd-mac\(n)", userId: "usr-me",
                     members: [], brokerHost: "broker.example",
                     relayURL: URL(string: "https://relay.example")!)
    }

    func testFirstCircleGetsDefaultShortcutLaterOnesDoNot() {
        let store = CircleStore(defaults: defaults)
        let first = store.add(config: config(1))
        let second = store.add(config: config(2))
        XCTAssertEqual(first.shortcut, .commandOptionR)
        XCTAssertNil(second.shortcut, "circles never default to a taken shortcut")
    }

    func testBindMovesShortcutAndReportsDisplacedCircle() {
        let store = CircleStore(defaults: defaults)
        let first = store.add(config: config(1))
        let second = store.add(config: config(2))
        let displaced = store.bind(.commandOptionR, to: second.id)
        XCTAssertEqual(displaced?.id, first.id)
        XCTAssertNil(store.circles.first { $0.id == first.id }?.shortcut)
        XCTAssertEqual(store.circles.first { $0.id == second.id }?.shortcut, .commandOptionR)
    }

    func testPersistsAcrossInstances() {
        let store = CircleStore(defaults: defaults)
        let circle = store.add(config: config(1))
        store.advanceTxIndex(id: circle.id, to: 42)

        let reloaded = CircleStore(defaults: defaults)
        XCTAssertEqual(reloaded.circles.count, 1)
        XCTAssertEqual(reloaded.circles.first?.config.circleId, "cir-1")
        XCTAssertEqual(reloaded.circles.first?.lastTxIndex, 42)
    }

    func testTxIndexNeverRewinds() {
        let store = CircleStore(defaults: defaults)
        let circle = store.add(config: config(1))
        store.advanceTxIndex(id: circle.id, to: 42)
        store.advanceTxIndex(id: circle.id, to: 7)
        XCTAssertEqual(store.circles.first?.lastTxIndex, 42)
    }

    func testRemove() {
        let store = CircleStore(defaults: defaults)
        let circle = store.add(config: config(1))
        store.remove(id: circle.id)
        XCTAssertTrue(store.circles.isEmpty)
    }
}
