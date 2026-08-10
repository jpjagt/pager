import XCTest
@testable import VoiceCore

final class ControlMessageTests: XCTestCase {
    func testDecodesTxStartIgnoringUnknownKeys() throws {
        let json = """
        { "v": 1, "type": "tx.start", "txn_id": "9f1c", "sender": "vpd-3fa2c81b",
          "circle": "cir-77b0e4d9", "tx_index": 4127, "codec": "opus",
          "sample_rate": 16000, "frame_ms": 60, "ts": 1754650000,
          "future_field": {"nested": true} }
        """
        guard case .txStart(let start) = try ControlWire.decode(Data(json.utf8)) else {
            return XCTFail("expected tx.start")
        }
        XCTAssertEqual(start.txnId, "9f1c")
        XCTAssertEqual(start.txIndex, 4127)
        XCTAssertEqual(start.frameMs, 60)
    }

    func testDecodesTxEndAndAbort() throws {
        let end = try ControlWire.decode(Data(
            #"{ "v": 1, "type": "tx.end", "txn_id": "a", "duration_ms": 8460, "frame_count": 141 }"#.utf8))
        XCTAssertEqual(end, .txEnd(TxEnd(txnId: "a", durationMs: 8460, frameCount: 141)))
        let abort = try ControlWire.decode(Data(
            #"{ "v": 1, "type": "tx.abort", "txn_id": "b", "reason": "sender_disconnect" }"#.utf8))
        XCTAssertEqual(abort, .txAbort(TxAbort(txnId: "b", reason: "sender_disconnect")))
    }

    func testUnknownTypeDecodesToUnknownNotError() throws {
        let message = try ControlWire.decode(Data(
            #"{ "v": 1, "type": "config.circle", "whatever": 1 }"#.utf8))
        XCTAssertEqual(message, .unknown(type: "config.circle"))
    }

    func testUnknownMajorVersionDecodesToUnknown() throws {
        let message = try ControlWire.decode(Data(
            #"{ "v": 2, "type": "tx.start" }"#.utf8))
        XCTAssertEqual(message, .unknown(type: "tx.start"))
    }

    func testMissingTypeThrows() {
        XCTAssertThrowsError(try ControlWire.decode(Data(#"{ "txn_id": "x" }"#.utf8)))
    }

    func testMissingVDefaultsToCurrentVersion() throws {
        // The schemas mark `v` optional-with-default; leniency is required.
        let message = try ControlWire.decode(Data(
            #"{ "type": "tx.end", "txn_id": "a", "duration_ms": 100 }"#.utf8))
        XCTAssertEqual(message, .txEnd(TxEnd(txnId: "a", durationMs: 100)))
    }

    func testReceiptPatchPreservesUnknownKeysAndNull() throws {
        let json = """
        { "v": 1, "type": "receipt.patch", "txn_id": "t1", "device_id": "vpd-aa",
          "patch": { "heard_at": 1754650100, "starred_at": 99, "old_key": null } }
        """
        guard case .receiptPatch(let patch) = try ControlWire.decode(Data(json.utf8)) else {
            return XCTFail("expected receipt.patch")
        }
        XCTAssertEqual(patch.deviceId, "vpd-aa")
        XCTAssertEqual(patch.patch["heard_at"], .int(1754650100))
        XCTAssertEqual(patch.patch["starred_at"], .int(99)) // unknown key kept
        XCTAssertEqual(patch.patch["old_key"], .null) // null means delete — kept
    }

    func testOutboundReceiptPatchCarriesEnvelopeAndNoDeviceId() throws {
        let data = try ControlWire.encode(ReceiptPatch(
            txnId: "t2", patch: ["heard_at": .int(123), "saved": .bool(true)]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["type"] as? String, "receipt.patch")
        XCTAssertNil(object["device_id"])
        let patch = try XCTUnwrap(object["patch"] as? [String: Any])
        XCTAssertEqual(patch["heard_at"] as? Int, 123)
        XCTAssertEqual(patch["saved"] as? Bool, true)
    }

    func testOutboundClientStatsShape() throws {
        let data = try ControlWire.encode(ClientStats(
            txnId: "t3", underruns: 1, minBufferMs: 340, startBufferMs: 500))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "client.stats")
        XCTAssertEqual(object["min_buffer_ms"] as? Int, 340)
    }

    func testReceiptScopes() {
        XCTAssertEqual(ControlWire.receiptScope(of: "delivered_at"), .device)
        XCTAssertEqual(ControlWire.receiptScope(of: "heard_at"), .user)
        XCTAssertEqual(ControlWire.receiptScope(of: "saved"), .user)
        XCTAssertNil(ControlWire.receiptScope(of: "starred_at"))
    }

    func testCircleConfigResolvesDeviceToUser() {
        let config = CircleConfig(
            circleId: "cir-1", deviceId: "vpd-mac", userId: "usr-me",
            members: [
                CircleMember(userId: "usr-me", deviceIds: ["vpd-pendant"]),
                CircleMember(userId: "usr-friend", deviceIds: ["vpd-f1", "vpd-f2"]),
            ],
            brokerHost: "broker.example", relayURL: URL(string: "https://relay.example")!)
        XCTAssertEqual(config.userId(forDevice: "vpd-mac"), "usr-me")
        XCTAssertEqual(config.userId(forDevice: "vpd-pendant"), "usr-me")
        XCTAssertEqual(config.userId(forDevice: "vpd-f2"), "usr-friend")
        XCTAssertNil(config.userId(forDevice: "vpd-stranger"))
    }
}
