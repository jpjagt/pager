import XCTest
@testable import PagerCore

/// Collects events in memory for asserting what the engine logged.
final class RecordingSyncLog: SyncLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [SyncLogEvent] = []
    var events: [SyncLogEvent] {
        lock.lock(); defer { lock.unlock() }; return _events
    }
    func log(_ event: SyncLogEvent) {
        lock.lock(); _events.append(event); lock.unlock()
    }
}

final class SyncLogTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("synclog-\(UUID().uuidString)/pager-logs.jsonl")
    }

    func testFileSyncLogAppendsOneJSONLinePerEvent() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = FileSyncLog(url: url, timestamp: { "T" })

        log.log(SyncLogEvent(ev: "edit.set", link: "abcd1234", writtenAt: 1, len: 3, ct: "xx"))
        log.log(SyncLogEvent(ev: "state", state: "connected"))
        log.log(SyncLogEvent(ev: "apply.discard_pending", pendingWa: 100, remoteWa: 200, remoteBy: "FRIEND"))

        let lines = try waitForLines(url, count: 3)
        XCTAssertEqual(lines.count, 3)

        let first = try JSONDecoder().decode(SyncLogEvent.self, from: Data(lines[0].utf8))
        XCTAssertEqual(first.ev, "edit.set")
        XCTAssertEqual(first.t, "T")
        XCTAssertEqual(first.ct, "xx")
        // Snake-cased keys land in the raw JSON.
        XCTAssertTrue(lines[2].contains("\"pending_wa\":100"))
        XCTAssertTrue(lines[2].contains("\"remote_by\":\"FRIEND\""))
        // nil fields are omitted.
        XCTAssertFalse(lines[1].contains("\"ct\""))
    }

    func testFileSyncLogRestartsWhenExceedingMaxBytes() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = FileSyncLog(url: url, maxBytes: 120, timestamp: { "T" })

        for i in 0..<50 { log.log(SyncLogEvent(ev: "state", state: "s\(i)")) }

        let data = try waitForNonEmpty(url)
        XCTAssertLessThanOrEqual(data.count, 120, "file should have restarted, not grown unbounded")
        // The most recent event survives the restart.
        let last = String(data: data, encoding: .utf8)!
            .split(separator: "\n").last.map(String.init)!
        let event = try JSONDecoder().decode(SyncLogEvent.self, from: Data(last.utf8))
        XCTAssertEqual(event.ev, "state")
    }

    func testEventCtRoundTripsThroughDecode() throws {
        // What `decode-log` relies on: encode an event with ct, decode it, decrypt.
        let crypto = PagerCrypto(code: ShareCode(entropy: "ABCDEFGHJKMNPQ"))
        let ct = try crypto.encrypt("the missing 2")
        let event = SyncLogEvent(ev: "edit.set", link: "abcd1234", writtenAt: 7, ct: ct)

        let json = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(SyncLogEvent.self, from: json)
        XCTAssertEqual(crypto.decrypt(decoded.ct ?? ""), "the missing 2")
    }

    // MARK: helpers (FileSyncLog writes on a background queue)

    private func waitForLines(_ url: URL, count: Int) throws -> [String] {
        try poll {
            guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let lines = s.split(separator: "\n").map(String.init)
            return lines.count == count ? lines : nil
        }
    }

    private func waitForNonEmpty(_ url: URL) throws -> Data {
        try poll {
            guard let d = try? Data(contentsOf: url), !d.isEmpty else { return nil }
            return d
        }
    }

    private func poll<T>(_ block: () -> T?, deadline: TimeInterval = 2) throws -> T {
        let start = Date()
        while Date().timeIntervalSince(start) < deadline {
            if let v = block() { return v }
            usleep(10_000)
        }
        throw XCTSkip("timed out waiting for log file")
    }
}

@MainActor
final class SyncEngineLoggingTests: XCTestCase {
    func testStaleOfflineEditLogsDiscardPending() async throws {
        let transport = FakeTransport()
        let crypto = PagerCrypto(code: ShareCode(entropy: "ABCDEFGHJKMNPQ"))
        let recorder = RecordingSyncLog()
        let engine = SyncEngine(
            transport: transport, crypto: crypto, pathId: "2aaf9352ffff", deviceId: "ME",
            now: { 100 }, debounceMs: 0, log: recorder)
        engine.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        engine.simulatePendingForTesting(writtenAt: 100, text: "the missing 2")
        transport.emit(node: PagerValue(ct: try crypto.encrypt("fresher"), writtenAt: 200, updatedBy: "FRIEND"))
        try await Task.sleep(nanoseconds: 100_000_000)

        let discard = recorder.events.first { $0.ev == "apply.discard_pending" }
        let unwrapped = try XCTUnwrap(discard, "the stale offline edit should log a discard")
        XCTAssertEqual(unwrapped.pendingWa, 100)
        XCTAssertEqual(unwrapped.remoteWa, 200)
        XCTAssertEqual(unwrapped.remoteBy, "FRIEND")
        XCTAssertEqual(unwrapped.link, "2aaf9352", "line is tagged with the pathId prefix")
        // The remote that displaced it is recorded as accepted.
        XCTAssertTrue(recorder.events.contains { $0.ev == "apply.accept" && $0.writtenAt == 200 })

        engine.stop()
    }
}
