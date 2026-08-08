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

    // MARK: - Open-fresh editing
    //
    // The wipe is driven from the app layer, which sees the key press before
    // the text field does (SwiftUI ignores a shortened binding value while the
    // field is being edited, so it cannot be done from inside `edit`). What is
    // tested here is the state machine the key monitor drives.

    func testTakeFreshEditClearsTheMessageAndRemembersIt() {
        session.beginFreshEdit()
        XCTAssertTrue(session.takeFreshEdit())
        XCTAssertEqual(session.text, "")
        XCTAssertTrue(session.canRestoreReplaced)
    }

    func testOnlyTheFirstKeystrokeWipes() {
        session.beginFreshEdit()
        XCTAssertTrue(session.takeFreshEdit())
        session.edit("new message")
        XCTAssertFalse(session.takeFreshEdit(), "the window closes after one wipe")
        XCTAssertEqual(session.text, "new message")
    }

    func testUnarmedSessionNeverWipes() {
        XCTAssertFalse(session.takeFreshEdit())
        XCTAssertEqual(session.text, "hello")
    }

    func testGraceTimeoutEndsTheWindow() {
        session.beginFreshEdit()
        session.endFreshEdit() // the 10 s timer
        XCTAssertFalse(session.takeFreshEdit())
        XCTAssertEqual(session.text, "hello")
    }

    func testDeletionOrNavigationEndsTheWindowButKeepsUndo() {
        session.beginFreshEdit()
        session.cancelReplaceOnType() // arrow key, backspace, or a click
        XCTAssertFalse(session.takeFreshEdit(), "typing now edits the message, it doesn't replace it")
        XCTAssertEqual(session.text, "hello")
    }

    func testClickAfterAWipeKeepsTheUndo() {
        session.beginFreshEdit()
        session.takeFreshEdit()
        session.cancelReplaceOnType()
        XCTAssertTrue(session.canRestoreReplaced, "clicking must not cost the user the undo")
    }

    func testWipingAnEmptyMessageLeavesNothingToUndo() {
        store.updateCachedText(id: link.id, text: "", writtenAt: 2)
        let fresh = EditorSession(linkId: link.id, store: store, committer: committer)
        fresh.beginFreshEdit()
        XCTAssertFalse(fresh.takeFreshEdit(), "nothing was thrown away, so the field needn't be touched")
        XCTAssertFalse(fresh.canRestoreReplaced)
    }

    func testUndoBringsBackTheReplacedMessage() {
        session.beginFreshEdit()
        session.takeFreshEdit()
        session.edit("typed since the wipe") // undo still targets the wipe
        XCTAssertTrue(session.restoreReplaced())
        XCTAssertEqual(session.text, "hello")
        XCTAssertFalse(session.canRestoreReplaced, "one restore, not a repeating toggle")
    }

    func testUndoBringsBackAReplacedImage() throws {
        let jpeg = try ImageCodec.process(TestImageFactory.png(width: 100, height: 100))
        store.updateCachedContent(id: link.id, content: .image(jpeg), writtenAt: 2)
        let fresh = EditorSession(linkId: link.id, store: store, committer: committer)
        fresh.beginFreshEdit()
        XCTAssertTrue(fresh.takeFreshEdit())
        XCTAssertNil(fresh.draftImageData)
        XCTAssertTrue(fresh.restoreReplaced())
        XCTAssertEqual(fresh.draftImageData, jpeg)
    }

    func testRestoredMessageIsCommittable() {
        session.beginFreshEdit()
        session.takeFreshEdit()
        session.restoreReplaced()
        session.commit()
        XCTAssertEqual(committer.lastContent, .text("hello"),
                       "restore leaves a dirty draft: sending must push the message that came back")
    }

    func testNothingToUndoWithoutAWipe() {
        session.edit("just typing")
        XCTAssertFalse(session.canRestoreReplaced)
        XCTAssertFalse(session.restoreReplaced(), "false lets the text field's own undo handle ⌘Z")
    }

    func testSendingEndsTheWindow() {
        session.beginFreshEdit()
        session.takeFreshEdit()
        session.edit("sent")
        session.commit()
        XCTAssertFalse(session.canRestoreReplaced)
    }

    func testDroppedTextEndsTheWindow() {
        session.beginFreshEdit()
        session.replaceText("dropped text")
        XCTAssertEqual(session.text, "dropped text")
        XCTAssertFalse(session.takeFreshEdit(), "a drop said what the pager holds; typing must not wipe it")
    }

    func testDroppedImageEndsTheWindow() throws {
        session.beginFreshEdit()
        try session.setImage(TestImageFactory.png(width: 100, height: 100))
        XCTAssertFalse(session.takeFreshEdit(), "the image was an explicit replacement, not a silent wipe")
        XCTAssertNotNil(session.draftImageData)
    }
}
