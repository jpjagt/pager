import XCTest
@testable import VoiceCore

final class MqttPacketCodecTests: XCTestCase {
    private func roundTrip(_ packet: MqttPacket, file: StaticString = #filePath,
                           line: UInt = #line) throws {
        var decoder = MqttPacketDecoder()
        let decoded = try decoder.feed(MqttPacketEncoder.encode(packet))
        XCTAssertEqual(decoded, [packet], file: file, line: line)
    }

    func testRoundTripsEveryPacket() throws {
        try roundTrip(.connect(clientId: "vpd-3fa2c81b", keepAliveSeconds: 300,
                               cleanStart: false, sessionExpirySeconds: 7 * 86_400))
        try roundTrip(.connack(sessionPresent: true, reasonCode: 0))
        try roundTrip(.connack(sessionPresent: false, reasonCode: 0x80))
        try roundTrip(.subscribe(packetId: 7, topic: "v1/dev/vpd-aa/dl", qos: 1))
        try roundTrip(.suback(packetId: 7, reasonCodes: [1]))
        try roundTrip(.publish(topic: "v1/dev/vpd-aa/up", packetId: 9,
                               payload: Data("{}".utf8), qos: 1, dup: false))
        try roundTrip(.publish(topic: "t", packetId: nil, payload: Data([1, 2, 3]),
                               qos: 0, dup: false))
        try roundTrip(.puback(packetId: 9))
        try roundTrip(.pingreq)
        try roundTrip(.pingresp)
        try roundTrip(.disconnect(reasonCode: 0x8E))
    }

    func testDecodesAcrossByteAtATimeFeeds() throws {
        let packets: [MqttPacket] = [
            .connack(sessionPresent: true, reasonCode: 0),
            .publish(topic: "v1/dev/vpd-aa/dl", packetId: 3,
                     payload: Data(repeating: 0x41, count: 200), qos: 1, dup: false),
            .pingresp,
        ]
        let stream = packets.map(MqttPacketEncoder.encode).reduce(Data(), +)
        var decoder = MqttPacketDecoder()
        var decoded: [MqttPacket] = []
        for byte in stream {
            decoded.append(contentsOf: try decoder.feed(Data([byte])))
        }
        XCTAssertEqual(decoded, packets)
    }

    func testMultiByteRemainingLength() throws {
        // 200-byte payload forces a 2-byte varint remaining length.
        let packet = MqttPacket.publish(topic: "t", packetId: nil,
                                        payload: Data(repeating: 0, count: 200),
                                        qos: 0, dup: false)
        let encoded = MqttPacketEncoder.encode(packet)
        XCTAssertNotEqual(encoded[1] & 0x80, 0) // continuation bit set
        try roundTrip(packet)
    }

    func testUnknownPacketTypeDecodesToUnknown() throws {
        // AUTH (type 15) with an empty body — must not throw, must not desync.
        var data = Data([0xF0, 0x00])
        data.append(MqttPacketEncoder.encode(.pingresp))
        var decoder = MqttPacketDecoder()
        XCTAssertEqual(try decoder.feed(data), [.unknown(type: 15), .pingresp])
    }

    func testConnackWithPropertiesStillParses() throws {
        // CONNACK carrying properties (e.g. assigned client id) — skipped.
        var body = Data([0x01, 0x00])
        var properties = Data()
        properties.append(0x12) // assigned client identifier
        properties.appendMqttString("assigned")
        body.appendVarint(properties.count)
        body.append(properties)
        var packet = Data([0x20])
        packet.appendVarint(body.count)
        packet.append(body)
        var decoder = MqttPacketDecoder()
        XCTAssertEqual(try decoder.feed(packet),
                       [.connack(sessionPresent: true, reasonCode: 0)])
    }

    func testBarePubackWithoutReasonCode() throws {
        // MQTT 5 allows PUBACK with remaining length 2 (packet id only).
        var data = Data([0x40, 0x02])
        data.appendBE(UInt16(9))
        var decoder = MqttPacketDecoder()
        XCTAssertEqual(try decoder.feed(data), [.puback(packetId: 9)])
    }

    func testMalformedVarintThrows() {
        var decoder = MqttPacketDecoder()
        XCTAssertThrowsError(try decoder.feed(Data([0x30, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]))) {
            XCTAssertEqual($0 as? MqttError, .malformedVarint)
        }
    }

    func testTruncatedStringThrows() {
        // PUBLISH claiming a 100-byte topic in a 4-byte body.
        var data = Data([0x30, 0x04])
        data.appendBE(UInt16(100))
        data.append(contentsOf: [0x61, 0x62])
        var decoder = MqttPacketDecoder()
        XCTAssertThrowsError(try decoder.feed(data))
    }

    func testConnectSessionExpiryRoundTrips() throws {
        let encoded = MqttPacketEncoder.encode(.connect(
            clientId: "c", keepAliveSeconds: 60, cleanStart: true,
            sessionExpirySeconds: 604_800))
        var decoder = MqttPacketDecoder()
        guard case .connect(_, _, let cleanStart, let expiry)? =
                try decoder.feed(encoded).first else {
            return XCTFail("expected connect")
        }
        XCTAssertTrue(cleanStart)
        XCTAssertEqual(expiry, 604_800)
    }
}
