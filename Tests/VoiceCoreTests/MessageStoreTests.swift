import XCTest
@testable import VoiceCore

final class MessageStoreTests: XCTestCase {
    private var dir: URL!
    private let circle = UUID()

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-store-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func store(budget: Int = .max) -> MessageStore {
        MessageStore(baseURL: dir, diskBudgetBytes: budget)
    }

    private func stored(_ n: Int64, heard: Bool = false, saved: Bool = false) -> StoredMessage {
        StoredMessage(txnId: "txn\(n)", txIndex: n, sender: "vpd-a",
                      heard: heard, saved: saved)
    }

    func testAudioRoundTrip() {
        let s = store()
        s.writeAudio(circleId: circle, txnId: "t1", bytes: Data([1, 2, 3]))
        XCTAssertEqual(s.readAudio(circleId: circle, txnId: "t1"), Data([1, 2, 3]))
        XCTAssertTrue(s.hasAudio(circleId: circle, txnId: "t1"))
        XCTAssertNil(s.readAudio(circleId: circle, txnId: "missing"))
    }

    func testIndexSortsByTxIndexAndUpsertsById() {
        let s = store()
        s.upsert(circleId: circle, stored(5))
        s.upsert(circleId: circle, stored(2))
        var updated = stored(5)
        updated.heard = true
        s.upsert(circleId: circle, updated)
        let index = s.index(circleId: circle)
        XCTAssertEqual(index.map(\.txIndex), [2, 5])
        XCTAssertEqual(index.last?.heard, true)
        XCTAssertEqual(s.index(circleId: circle).count, 2)
    }

    func testPersistsAcrossInstances() {
        store().upsert(circleId: circle, stored(1))
        XCTAssertEqual(store().index(circleId: circle).count, 1)
    }

    func testEvictionProtectsUnheardSavedAndMostRecent() {
        let s = store(budget: 250) // each audio blob is 100 bytes
        let blob = Data(repeating: 0, count: 100)
        for n: Int64 in 1 ... 4 {
            s.upsert(circleId: circle, stored(
                n, heard: n != 2, saved: n == 3)) // 2 unheard, 3 saved, 4 newest
            s.writeAudio(circleId: circle, txnId: "txn\(n)", bytes: blob)
        }
        // 400 bytes > 250: only txn1 (heard, unsaved, not newest) is evictable.
        let remaining = s.index(circleId: circle).map(\.txnId)
        XCTAssertFalse(remaining.contains("txn1"), "heard+unsaved+old is evicted")
        XCTAssertTrue(remaining.contains("txn2"), "unheard is never evicted")
        XCTAssertTrue(remaining.contains("txn3"), "saved is never evicted")
        XCTAssertTrue(remaining.contains("txn4"), "most recent is never evicted")
        XCTAssertFalse(s.hasAudio(circleId: circle, txnId: "txn1"))
        XCTAssertTrue(s.hasAudio(circleId: circle, txnId: "txn2"))
    }

    func testRemoveCircleDeletesEverything() {
        let s = store()
        s.upsert(circleId: circle, stored(1))
        s.writeAudio(circleId: circle, txnId: "txn1", bytes: Data([1]))
        s.removeCircle(circleId: circle)
        XCTAssertTrue(s.index(circleId: circle).isEmpty)
        XCTAssertFalse(s.hasAudio(circleId: circle, txnId: "txn1"))
    }
}
