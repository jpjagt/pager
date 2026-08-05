import XCTest
@testable import PagerCore

/// Captures committed content instead of touching the network.
@MainActor
final class StubCommitter: ContentCommitter {
    var lastContent: PagerContent?
    func commitContent(_ content: PagerContent) { lastContent = content }
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
        XCTAssertNil(committer.lastContent, "edit must not commit")
        XCTAssertEqual(store.links.first?.cachedText, "hello", "edit must not touch the cache/menu bar")
    }

    func testCommitSendsAndUpdatesCache() {
        session.edit("new message")
        session.commit()
        XCTAssertEqual(committer.lastContent, .text("new message"))
        XCTAssertEqual(store.links.first?.cachedText, "new message")
    }

    func testCommitWithoutEditIsNoOp() {
        session.commit()
        XCTAssertNil(committer.lastContent)
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

    func testSetImageCommitsImageContent() throws {
        let raw = TestImageFactory.png(width: 800, height: 600)
        try session.setImage(raw)
        XCTAssertNotNil(session.draftImageData)
        XCTAssertEqual(session.text, "")
        session.commit()
        guard case .image(let sent)? = committer.lastContent else {
            return XCTFail("expected image commit")
        }
        XCTAssertTrue(ImageCodec.isDecodableImage(sent))
        XCTAssertLessThanOrEqual(sent.count, ImageCodec.maxEncodedBytes)
        XCTAssertEqual(store.cachedContent(id: link.id), .image(sent))
    }

    func testSetImageRejectsGarbageAndKeepsDraft() {
        session.edit("my draft")
        XCTAssertThrowsError(try session.setImage(Data("junk".utf8)))
        XCTAssertEqual(session.text, "my draft") // draft untouched on failure
    }

    func testTypingReplacesImageDraft() throws {
        try session.setImage(TestImageFactory.png(width: 100, height: 100))
        session.edit("words now")
        XCTAssertNil(session.draftImageData)
        session.commit()
        XCTAssertEqual(committer.lastContent, .text("words now"))
    }

    func testClearFromTextDraftEmptiesItAndStaysDirty() {
        session.edit("draft in progress")
        session.clear()
        XCTAssertEqual(session.text, "")
        XCTAssertNil(session.draftImageData)
        session.commit()
        XCTAssertEqual(committer.lastContent, .text(""), "clear() must stay dirty, not commit itself")
    }

    func testClearFromImageDraftEmptiesBothAndStaysDirty() throws {
        try session.setImage(TestImageFactory.png(width: 100, height: 100))
        session.clear()
        XCTAssertNil(session.draftImageData)
        XCTAssertEqual(session.text, "")
        session.commit()
        XCTAssertEqual(committer.lastContent, .text(""))
    }

    func testDiscardRestoresCachedContentAndClearsDirty() {
        session.edit("draft in progress")
        session.discard()
        XCTAssertEqual(session.text, "hello")
        session.commit()
        XCTAssertNil(committer.lastContent, "discard() must clear dirty so commit() is a no-op")
        XCTAssertEqual(store.links.first?.cachedText, "hello")
    }

    func testCommitAfterDiscardPushesNothing() {
        session.edit("draft in progress")
        session.discard()
        session.commit()
        XCTAssertNil(committer.lastContent)
    }

    func testDiscardPicksUpRemoteValueLandedMidEdit() {
        session.edit("my draft")
        store.updateCachedText(id: link.id, text: "their message", writtenAt: 2)
        session.discard()
        XCTAssertEqual(session.text, "their message", "discard() reverts to cached content, so a remote update mid-edit wins")
    }

    func testSessionOpensOnCachedImage() throws {
        let jpeg = try ImageCodec.process(TestImageFactory.png(width: 100, height: 100))
        store.updateCachedContent(id: link.id, content: .image(jpeg), writtenAt: 1)
        let fresh = EditorSession(linkId: link.id, store: store, committer: committer)
        XCTAssertEqual(fresh.draftImageData, jpeg)
    }
}
