import XCTest
@testable import VoiceCore

@MainActor
final class VoiceEngineTests: XCTestCase {
    private var engine: VoiceEngine!
    private var signal: FakeSignal!
    private var transport: FakeVoiceTransport!
    private var audio: FakeAudioIO!
    private var messages: MessageStore!
    private var circles: CircleStore!
    private var circleId: UUID!
    private var storeDir: URL!
    private var suiteName: String!
    private var leds: [VoiceEngine.Led] = []

    private let config = CircleConfig(
        circleId: "cir-1", deviceId: "vpd-mac", userId: "usr-me",
        members: [
            CircleMember(userId: "usr-me", deviceIds: ["vpd-pendant"]),
            CircleMember(userId: "usr-friend", deviceIds: ["vpd-friend"]),
        ],
        brokerHost: "b", relayURL: URL(string: "https://r")!)

    override func setUp() {
        super.setUp()
        storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-engine-\(UUID().uuidString)")
        suiteName = "voice-engine-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        circles = CircleStore(defaults: defaults)
        circleId = circles.add(config: config).id
        messages = MessageStore(baseURL: storeDir)
        signal = FakeSignal()
        transport = FakeVoiceTransport()
        audio = FakeAudioIO()
        leds = []
        engine = VoiceEngine(circleId: circleId, config: config, signal: signal,
                             transport: transport, codec: FakeOpusCodec(),
                             audio: audio, messages: messages, circles: circles,
                             now: { 1_754_650_000 })
        engine.onLed = { [weak self] in self?.leds.append($0) }
        engine.start()
        signal.onState?(.connected)
    }

    override func tearDown() {
        engine.stop()
        try? FileManager.default.removeItem(at: storeDir)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func waitUntil(timeout: TimeInterval = 2,
                           _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func deliverStart(txn: String = "aaaa", index: Int64 = 1,
                              sender: String = "vpd-friend") {
        signal.deliver("""
        { "v": 1, "type": "tx.start", "txn_id": "\(txn)", "sender": "\(sender)",
          "circle": "cir-1", "tx_index": \(index), "frame_ms": 60 }
        """)
    }

    private func deliverEnd(txn: String = "aaaa", frames: Int = 3) {
        signal.deliver("""
        { "v": 1, "type": "tx.end", "txn_id": "\(txn)",
          "duration_ms": \(frames * 60), "frame_count": \(frames) }
        """)
    }

    private let testFrames: [[Int16]] = [[100, -100, 200, -200],
                                         [300, -300, 400, -400],
                                         [500, -500, 600, -600]]

    // MARK: - Inbound lifecycle

    func testStartEndDownloadsStoresAndReportsDelivered() async {
        transport.scriptDownload(txnId: "aaaa", chunks: [VLKFixtures.body(frames: testFrames)])
        deliverStart()
        XCTAssertTrue(leds.contains(.incoming), "open transmission shows amber")
        deliverEnd()
        let stored = await waitUntil {
            self.messages.hasAudio(circleId: self.circleId, txnId: "aaaa")
        }
        XCTAssertTrue(stored)
        let delivered = await waitUntil {
            self.signal.publishedMessages().contains {
                ($0["type"] as? String) == "receipt.patch"
                    && (($0["patch"] as? [String: Any])?["delivered_at"] as? Int) != nil
            }
        }
        XCTAssertTrue(delivered, "delivered_at fires once the stream is on disk")
        XCTAssertEqual(engine.unheardCount, 1)
        XCTAssertEqual(leds.last, .unheard(1))
        XCTAssertEqual(circles.circles.first?.lastTxIndex, 1, "cursor advanced")
    }

    func testDuplicateTxStartIsIdempotent() {
        deliverStart()
        deliverStart()
        XCTAssertEqual(messages.index(circleId: circleId).count, 1)
    }

    func testOwnEchoIsIgnoredButAdvancesCursor() {
        deliverStart(index: 9, sender: "vpd-mac")
        XCTAssertEqual(messages.index(circleId: circleId).count, 0)
        XCTAssertEqual(circles.circles.first?.lastTxIndex, 9)
    }

    func testAbortRemovesEntry() {
        deliverStart()
        signal.deliver(#"{ "v": 1, "type": "tx.abort", "txn_id": "aaaa" }"#)
        XCTAssertEqual(messages.index(circleId: circleId).count, 0)
        XCTAssertEqual(engine.unheardCount, 0)
        XCTAssertEqual(leds.last, .idle)
    }

    func testHeardOnAnotherOfMyClientsDropsUnheardHere() async {
        transport.scriptDownload(txnId: "aaaa", chunks: [VLKFixtures.body(frames: testFrames)])
        deliverStart()
        deliverEnd()
        _ = await waitUntil { self.engine.unheardCount == 1 }
        // My pendant heard it: user-scoped receipt echo (§7.2).
        signal.deliver("""
        { "v": 1, "type": "receipt.patch", "txn_id": "aaaa",
          "device_id": "vpd-pendant", "patch": { "heard_at": 1754650100 } }
        """)
        XCTAssertEqual(engine.unheardCount, 0)
        XCTAssertEqual(leds.last, .idle)
    }

    func testAnotherUsersReceiptChangesNothing() async {
        transport.scriptDownload(txnId: "aaaa", chunks: [VLKFixtures.body(frames: testFrames)])
        deliverStart()
        deliverEnd()
        _ = await waitUntil { self.engine.unheardCount == 1 }
        signal.deliver("""
        { "v": 1, "type": "receipt.patch", "txn_id": "aaaa",
          "device_id": "vpd-friend", "patch": { "heard_at": 1754650100 } }
        """)
        XCTAssertEqual(engine.unheardCount, 1)
    }

    // MARK: - Playback

    private func storeCompleteMessage(txn: String, index: Int64) {
        messages.upsert(circleId: circleId, StoredMessage(
            txnId: txn, txIndex: index, sender: "vpd-friend", frameMs: 60))
        messages.writeAudio(circleId: circleId, txnId: txn,
                            bytes: VLKFixtures.body(frames: testFrames))
    }

    func testArchivePlaybackMarksHeardAndPublishesReceiptAndStats() async {
        storeCompleteMessage(txn: "aaaa", index: 1)
        engine.playTapped()
        XCTAssertEqual(leds.last, .playing)
        var rendered: [[Int16]] = []
        for _ in 0 ..< 10 {
            if let pcm = audio.tick() { rendered.append(pcm) }
        }
        XCTAssertEqual(rendered.count, 3, "all three frames rendered")
        XCTAssertEqual(rendered.first, testFrames[0])
        let heard = await waitUntil {
            self.messages.message(circleId: self.circleId, txnId: "aaaa")?.heard == true
        }
        XCTAssertTrue(heard)
        let types = signal.publishedMessages().compactMap { $0["type"] as? String }
        XCTAssertTrue(types.contains("receipt.patch"), "heard receipt published")
        XCTAssertTrue(types.contains("client.stats"), "telemetry published")
        XCTAssertEqual(leds.last, .idle)
    }

    func testTapDuringPlaybackStops() {
        storeCompleteMessage(txn: "aaaa", index: 1)
        engine.playTapped()
        _ = audio.tick()
        engine.playTapped() // stop
        XCTAssertEqual(audio.playbackStops, 1)
        XCTAssertEqual(messages.message(circleId: circleId, txnId: "aaaa")?.heard, false,
                       "stopping early is not hearing")
    }

    func testQueuePlaysConsecutivelyWithSeparator() async {
        storeCompleteMessage(txn: "aaaa", index: 1)
        storeCompleteMessage(txn: "bbbb", index: 2)
        engine.playTapped()
        var frames: [[Int16]] = []
        for _ in 0 ..< 20 {
            if let pcm = audio.tick() { frames.append(pcm) }
        }
        // 3 frames of aaaa + 3 separator frames + 3 frames of bbbb.
        XCTAssertEqual(frames.count, 9)
        XCTAssertEqual(frames[0], testFrames[0])
        XCTAssertEqual(frames[8], testFrames[2])
        let bothHeard = await waitUntil {
            self.messages.index(circleId: self.circleId).allSatisfy(\.heard)
        }
        XCTAssertTrue(bothHeard)
    }

    func testChasePlayRidesTheLiveStream() async {
        deliverStart(txn: "cccc", index: 3)
        engine.playTapped() // nothing on disk, transmission open → chase
        let connected = await waitUntil {
            self.transport.liveContinuation(txnId: "cccc") != nil
        }
        XCTAssertTrue(connected, "tap opened a live download")
        let live = transport.liveContinuation(txnId: "cccc")!

        let body = VLKFixtures.body(frames: testFrames)
        live.yield(body.prefix(20)) // header + part of frame 0
        live.yield(body.suffix(body.count - 20))
        let gotFrames = await waitUntil { self.audio.tick() != nil }
        XCTAssertTrue(gotFrames, "frames play as they arrive")
        live.finish()
        var rendered = 1
        _ = await waitUntil {
            while let _ = self.audio.tick() { rendered += 1 }
            return self.messages.hasAudio(circleId: self.circleId, txnId: "cccc")
        }
        XCTAssertEqual(rendered, 3, "chase-play rendered the full stream")
        let heard = await waitUntil {
            self.messages.message(circleId: self.circleId, txnId: "cccc")?.heard == true
        }
        XCTAssertTrue(heard)
    }

    // MARK: - Recording

    func testRecordFlowUploadsHeaderFramesAndEOM() async {
        engine.recordPressed()
        XCTAssertEqual(leds.last, .recording)
        XCTAssertTrue(audio.isCapturing)
        audio.feedMic([1, 2, 3, 4])
        audio.feedMic([5, 6, 7, 8])
        XCTAssertEqual(engine.recordingDurationMs, 120)
        engine.recordReleased()
        XCTAssertFalse(audio.isCapturing)
        let done = await waitUntil {
            self.transport.uploadAttempts.first?.completed == true
        }
        XCTAssertTrue(done)
        XCTAssertEqual(leds.last, .idle)

        var decoder = TxnStreamDecoder()
        let events = try! decoder.feed(transport.uploadAttempts[0].data)
        XCTAssertEqual(events.count, 4, "header + 2 frames + EOM")
        XCTAssertEqual(events.first, .header(StreamHeader()))
        XCTAssertEqual(events.last, .end(seq: 2))
        guard case .frame(_, let payload) = events[1] else { return XCTFail() }
        XCTAssertEqual(try FakeOpusCodec().decode(payload), [1, 2, 3, 4])
    }

    func testRecordingStopsPlaybackFirst() {
        storeCompleteMessage(txn: "aaaa", index: 1)
        engine.playTapped()
        engine.recordPressed()
        XCTAssertEqual(audio.playbackStops, 1, "invariant #1: never both at once")
        XCTAssertTrue(audio.isCapturing)
        engine.recordDiscarded()
    }

    func testUploadResumesFromServersNextSeq() async {
        transport.failUploadAttempts = [0]
        transport.scriptedStatus = TransmissionStatus(state: "open", nextSeq: 1)
        engine.recordPressed()
        audio.feedMic([1, 2, 3, 4])
        audio.feedMic([5, 6, 7, 8])
        engine.recordReleased()
        let resumed = await waitUntil(timeout: 4) {
            self.transport.uploadAttempts.count == 2
                && self.transport.uploadAttempts[1].completed
        }
        XCTAssertTrue(resumed)
        XCTAssertNil(transport.uploadAttempts[0].fromSeq)
        XCTAssertEqual(transport.uploadAttempts[1].fromSeq, 1, "resumed at next_seq")
        var decoder = TxnStreamDecoder(firstSeq: 1)
        let events = try! decoder.feed(transport.uploadAttempts[1].data)
        XCTAssertEqual(events.first, .header(StreamHeader()), "resumed body restates header")
        XCTAssertEqual(events.last, .end(seq: 2))
    }

    func testDiscardNeverSendsEOM() async {
        engine.recordPressed()
        audio.feedMic([1, 2, 3, 4])
        engine.recordDiscarded()
        try? await Task.sleep(nanoseconds: 100_000_000)
        for attempt in transport.uploadAttempts {
            var decoder = TxnStreamDecoder()
            let events = (try? decoder.feed(attempt.data)) ?? []
            XCTAssertFalse(events.contains { if case .end = $0 { return true } else { return false } },
                           "discard must leave the transmission open → server aborts it")
        }
        XCTAssertEqual(leds.last, .idle)
    }

    // MARK: - Catch-up

    func testSessionAbsentTriggersCatchupAndReconciles() async {
        transport.scriptDownload(txnId: "old1", chunks: [VLKFixtures.body(frames: testFrames)])
        transport.scriptedCatchup = [
            CatchupRecord(txnId: "old1", sender: "vpd-friend", circle: "cir-1",
                          txIndex: 4, frameMs: 60, state: "complete",
                          durationMs: 180, frameCount: 3),
            CatchupRecord(txnId: "gone", sender: "vpd-friend", circle: "cir-1",
                          txIndex: 5, state: "aborted"),
            CatchupRecord(txnId: "mine", sender: "vpd-mac", circle: "cir-1",
                          txIndex: 6, state: "complete"),
        ]
        signal.onSessionPresent?(false)
        let reconciled = await waitUntil {
            self.messages.hasAudio(circleId: self.circleId, txnId: "old1")
        }
        XCTAssertTrue(reconciled)
        XCTAssertEqual(transport.catchupCursors, [0])
        XCTAssertEqual(messages.index(circleId: circleId).map(\.txnId), ["old1"],
                       "aborted and own transmissions are not queued")
        XCTAssertEqual(circles.circles.first?.lastTxIndex, 6)
        XCTAssertEqual(engine.unheardCount, 1)
    }

    func testSessionPresentSkipsCatchup() async {
        signal.onSessionPresent?(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(transport.catchupCursors.isEmpty)
    }
}
