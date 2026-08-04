import XCTest
@testable import PagerCore

/// Captures committed text instead of touching the network.
final class StubCommitter: ContentCommitter {
    private(set) var committed: [String] = []
    func commitContent(_ content: PagerContent) { committed.append(content.textValue) }
}

@MainActor
final class EditorSessionTests: XCTestCase {
    var store: LinkStore!
    var committer: StubCommitter!
    var link: PagerLink!
    var session: EditorSession!
    private var suiteName = ""

    override func setUp() {
        suiteName = "editorsession-\(UUID().uuidString)"
        store = LinkStore(defaults: UserDefaults(suiteName: suiteName)!)
        committer = StubCommitter()
        link = store.add(code: ShareCode(entropy: "ABCDEFGHJKMNPQ"))
        store.updateCachedText(id: link.id, text: "hello", writtenAt: 1)
        session = EditorSession(linkId: link.id, store: store, committer: committer,
                                now: { 1_000 })
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func testStartsFromCachedText() {
        XCTAssertEqual(session.text, "hello")
    }

    func testEditDoesNotPropagate() {
        session.edit("draft in progress")
        XCTAssertEqual(session.text, "draft in progress")
        XCTAssertTrue(committer.committed.isEmpty, "edit must not commit")
        XCTAssertEqual(store.links.first?.cachedText, "hello", "edit must not touch the cache/menu bar")
    }

    func testCommitSendsAndUpdatesCache() {
        session.edit("new message")
        session.commit()
        XCTAssertEqual(committer.committed, ["new message"])
        XCTAssertEqual(store.links.first?.cachedText, "new message")
    }

    func testCommitWithoutEditIsNoOp() {
        session.commit()
        XCTAssertTrue(committer.committed.isEmpty)
        XCTAssertEqual(store.links.first?.cachedText, "hello")
    }

    func testRemoteValueDoesNotClobberLiveDraft() {
        session.edit("my draft")
        // Remote message lands in the cache (as engine.onText would do).
        store.updateCachedText(id: link.id, text: "their message", writtenAt: 2)
        XCTAssertEqual(session.text, "my draft", "remote must not overwrite the draft")
        XCTAssertEqual(session.currentRemoteText, "their message")
    }

    func testCharCapEnforced() {
        session.edit(String(repeating: "x", count: 600))
        XCTAssertEqual(session.text.count, 500)
    }
}
