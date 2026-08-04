import XCTest
@testable import PagerCore

/// Minimal transport stub: a settable node plus injectable get/put errors.
final class StubTransport: SyncTransport, @unchecked Sendable {
    var node: PagerValue?
    var getError: Error?
    var putError: Error?
    var puts: [(pathId: String, value: PagerValue)] = []

    func get(pathId: String) async throws -> PagerValue? {
        if let getError { throw getError }
        return node
    }
    func put(pathId: String, value: PagerValue) async throws {
        if let putError { throw putError }
        puts.append((pathId, value))
    }
    func stream(pathId: String) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
final class PagerActionsTests: XCTestCase {
    let code = ShareCode(entropy: "ABCDEFGHJKMNPQ")
    var transport: StubTransport!
    var store: LinkStore!
    var actions: PagerActions!
    private var suiteName = ""

    override func setUp() {
        suiteName = "pageractions-\(UUID().uuidString)"
        transport = StubTransport()
        store = LinkStore(defaults: UserDefaults(suiteName: suiteName)!)
        actions = PagerActions(transport: transport, store: store, now: { 1_000 })
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func testCreatePagerWritesEmptyNodeAndPersistsLink() async throws {
        let link = try await actions.createPager(code: code)
        XCTAssertEqual(store.links.map(\.id), [link.id])
        XCTAssertEqual(link.code, code.full)
        XCTAssertEqual(transport.puts.count, 1)
        // The initial node is an encrypted empty string so joiners can verify it.
        XCTAssertEqual(PagerCrypto(code: code).decrypt(transport.puts[0].value.ct), "")
    }

    func testCreatePagerNetworkFailureDoesNotPersist() async {
        transport.putError = URLError(.notConnectedToInternet)
        do {
            _ = try await actions.createPager(code: code)
            XCTFail("expected network error")
        } catch {
            XCTAssertEqual(error as? PagerActionError, .network)
        }
        XCTAssertTrue(store.links.isEmpty)
    }

    func testJoinInvalidCodeThrows() async {
        await assertThrows(.invalidCode) { try await self.actions.joinPager("not-a-code") }
    }

    func testJoinNonexistentNodeThrows() async {
        transport.node = nil
        await assertThrows(.nodeNotFound) { try await self.actions.joinPager(self.code.display) }
        XCTAssertTrue(store.links.isEmpty)
    }

    func testJoinAlreadyLinkedThrows() async throws {
        store.add(code: code)
        transport.node = PagerValue(ct: try PagerCrypto(code: code).encrypt("x"), writtenAt: 1, updatedBy: "F")
        await assertThrows(.alreadyLinked) { try await self.actions.joinPager(self.code.display) }
    }

    func testJoinSurfacesFriendMessageAndCachesIt() async throws {
        let crypto = PagerCrypto(code: code)
        transport.node = PagerValue(ct: try crypto.encrypt("hi there"), writtenAt: 42, updatedBy: "FRIEND")
        let result = try await actions.joinPager(code.display)
        XCTAssertEqual(result.friendMessage, "hi there")
        XCTAssertEqual(store.links.first?.cachedText, "hi there")
        XCTAssertEqual(store.links.first?.cachedWrittenAt, 42)
    }

    func testJoinWithEmptyNodeHasNoFriendMessage() async throws {
        transport.node = PagerValue(ct: try PagerCrypto(code: code).encrypt(""), writtenAt: 1, updatedBy: "F")
        let result = try await actions.joinPager(code.display)
        XCTAssertNil(result.friendMessage)
        XCTAssertEqual(store.links.first?.cachedText, "")
    }

    func testJoinWithWaitingImageCachesItAndOmitsFriendMessage() async throws {
        let code = ShareCode.generate()
        let crypto = PagerCrypto(code: code)
        let jpeg = try ImageCodec.process(TestImageFactory.png(width: 200, height: 150))
        let sealed = try crypto.encryptContent(.image(jpeg))
        transport.node = PagerValue(ct: sealed.ct, writtenAt: 9, updatedBy: "friend", type: sealed.type)

        let result = try await actions.joinPager(code.display)
        XCTAssertNil(result.friendMessage)
        XCTAssertEqual(store.cachedContent(id: result.link.id), .image(jpeg))
        XCTAssertEqual(store.links.first?.cachedWrittenAt, 9)
    }

    func testSendEncryptsPutsAndCaches() async throws {
        let link = store.add(code: code)
        try await actions.send(text: "yo", code: code, linkId: link.id)
        XCTAssertEqual(transport.puts.count, 1)
        XCTAssertEqual(PagerCrypto(code: code).decrypt(transport.puts[0].value.ct), "yo")
        XCTAssertEqual(transport.puts[0].value.writtenAt, 1_000)
        XCTAssertEqual(store.links.first?.cachedText, "yo")
    }

    private func assertThrows(_ expected: PagerActionError, _ block: () async throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await block()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PagerActionError, expected, file: file, line: line)
        }
    }
}
