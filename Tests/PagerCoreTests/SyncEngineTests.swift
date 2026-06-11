import XCTest
@testable import PagerCore

/// Scripted transport: hand it events to emit; records PUTs.
final class FakeTransport: SyncTransport, @unchecked Sendable {
    var puts: [PagerValue] = []
    var putError: Error?
    var putAttempts = 0
    private var continuation: AsyncThrowingStream<SSEEvent, Error>.Continuation?

    func get(pathId: String) async throws -> PagerValue? { nil }

    func put(pathId: String, value: PagerValue) async throws {
        putAttempts += 1
        if let putError { throw putError }
        puts.append(value)
    }

    func stream(pathId: String) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { self.continuation = $0 }
    }

    func emit(node: PagerValue?) {
        let data: String
        if let node {
            let updatedAt = node.updatedAt.map(String.init) ?? "0"
            data = #"{"path":"/","data":{"ct":"\#(node.ct)","writtenAt":\#(node.writtenAt),"updatedAt":\#(updatedAt),"updatedBy":"\#(node.updatedBy)"}}"#
        } else {
            data = #"{"path":"/","data":null}"#
        }
        continuation?.yield(SSEEvent(name: "put", data: data))
    }

    func dropStream() { continuation?.finish(throwing: URLError(.networkConnectionLost)) }
}

@MainActor
final class SyncEngineTests: XCTestCase {
    var transport: FakeTransport!
    var crypto: PagerCrypto!
    var clock: Int64 = 1_000
    var received: [String] = []
    var states: [SyncEngine.State] = []
    var engine: SyncEngine!

    override func setUp() async throws {
        transport = FakeTransport()
        crypto = PagerCrypto(code: ShareCode(entropy: "ABCDEFGHJKMNPQ"))
        received = []
        states = []
        engine = SyncEngine(
            transport: transport, crypto: crypto, pathId: "path", deviceId: "ME",
            now: { self.clock }, debounceMs: 0)
        engine.onText = { text, _ in self.received.append(text) }
        engine.onState = { self.states.append($0) }
        engine.start()
        try await Task.sleep(nanoseconds: 50_000_000) // let stream attach
    }

    override func tearDown() { engine.stop() }

    func remote(_ text: String, at writtenAt: Int64, by: String = "FRIEND") -> PagerValue {
        PagerValue(ct: try! crypto.encrypt(text), writtenAt: writtenAt, updatedBy: by)
    }

    func settle() async { try? await Task.sleep(nanoseconds: 100_000_000) }

    func testInitialSnapshotDecryptsAndConnects() async {
        transport.emit(node: remote("hi", at: 500))
        await settle()
        XCTAssertEqual(received, ["hi"])
        XCTAssertEqual(states.last, .connected)
    }

    func testNewerRemoteWinsOlderRemoteIgnored() async {
        transport.emit(node: remote("new", at: 900))
        transport.emit(node: remote("old", at: 800))
        await settle()
        XCTAssertEqual(received, ["new"])
    }

    func testOwnEchoIsSuppressed() async {
        transport.emit(node: remote("init", at: 1))
        await settle()
        engine.setText("mine")
        await settle()
        transport.emit(node: remote("mine-echo", at: clock, by: "ME"))
        await settle()
        XCTAssertEqual(received, ["init"]) // echo never re-delivered to UI
        XCTAssertEqual(transport.puts.map(\.updatedBy), ["ME"])
    }

    func testStalePendingIsDiscardedOnSnapshot() async {
        clock = 100
        engine.setText("stale local") // pending at writtenAt=100, PUT will record it
        await settle()
        transport.puts.removeAll() // pretend that PUT never reached the server
        engine.simulatePendingForTesting(writtenAt: 100, text: "stale local")
        transport.emit(node: remote("fresher remote", at: 200))
        await settle()
        XCTAssertEqual(received.last, "fresher remote")
        XCTAssertTrue(transport.puts.isEmpty) // stale pending NOT pushed
    }

    func testNewerPendingIsPushedOnSnapshot() async {
        engine.simulatePendingForTesting(writtenAt: 300, text: "newer local")
        transport.emit(node: remote("older remote", at: 200))
        await settle()
        XCTAssertEqual(transport.puts.map(\.writtenAt), [300])
        XCTAssertNotEqual(received.last, "older remote")
    }

    func testSetTextPutsDebouncedValue() async {
        clock = 2_000
        engine.setText("hello")
        await settle()
        XCTAssertEqual(transport.puts.count, 1)
        XCTAssertEqual(transport.puts[0].writtenAt, 2_000)
        XCTAssertEqual(crypto.decrypt(transport.puts[0].ct), "hello")
    }

    func testStreamDropSetsReconnecting() async {
        transport.emit(node: remote("hi", at: 1))
        await settle()
        transport.dropStream()
        await settle()
        XCTAssertEqual(states.last, .reconnecting)
    }

    func testPutFailureRetriesThenSucceeds() async throws {
        transport.putError = URLError(.notConnectedToInternet)
        engine.setText("retry me")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(states.contains(.reconnecting))
        XCTAssertTrue(transport.puts.isEmpty)
        transport.putError = nil
        try await Task.sleep(nanoseconds: 1_300_000_000) // first backoff delay is 1s
        XCTAssertEqual(transport.puts.count, 1)
        XCTAssertEqual(crypto.decrypt(transport.puts[0].ct), "retry me")
    }

    func testUndecryptableValueKeepsLastGoodText() async {
        transport.emit(node: remote("good", at: 100))
        await settle()
        transport.emit(node: PagerValue(ct: "!!!notbase64", writtenAt: 200, updatedBy: "FRIEND"))
        await settle()
        XCTAssertEqual(received, ["good"])
    }

    func testStopDuringFailedRetryStopsAttempts() async throws {
        transport.putError = URLError(.notConnectedToInternet)
        engine.setText("doomed")
        try await Task.sleep(nanoseconds: 200_000_000)
        let attemptsBeforeStop = transport.putAttempts
        engine.stop()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertLessThanOrEqual(transport.putAttempts, attemptsBeforeStop + 1) // no busy loop
    }

    func testStopCancelsAllLinksInFlushChain() async throws {
        transport.putError = URLError(.notConnectedToInternet)
        engine.setText("A")
        try await Task.sleep(nanoseconds: 200_000_000) // link 1 now in backoff sleep
        engine.setText("B") // link 2 chained behind link 1
        try await Task.sleep(nanoseconds: 100_000_000)
        let attemptsBeforeStop = transport.putAttempts
        engine.stop()
        // Longer than the 1s first backoff: a zombie link would have retried.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertLessThanOrEqual(transport.putAttempts, attemptsBeforeStop + 1)
        XCTAssertTrue(transport.puts.isEmpty)
    }
}
