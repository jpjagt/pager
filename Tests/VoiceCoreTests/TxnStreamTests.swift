import XCTest
@testable import VoiceCore

final class TxnStreamTests: XCTestCase {
    private func body(frames: [Data], eomSeq: UInt32?, header: StreamHeader = StreamHeader()) throws -> Data {
        var data = TxnStreamEncoder.header(header)
        for (i, payload) in frames.enumerated() {
            data.append(try TxnStreamEncoder.frameRecord(seq: UInt32(i), payload: payload))
        }
        if let eomSeq { data.append(TxnStreamEncoder.endOfMessage(seq: eomSeq)) }
        return data
    }

    func testHeaderEncodesToEightBytesWithMagic() {
        let data = TxnStreamEncoder.header(StreamHeader())
        XCTAssertEqual(data.count, 8)
        XCTAssertEqual([UInt8](data.prefix(4)), [0x56, 0x4C, 0x4B, 0x31]) // "VLK1"
        XCTAssertEqual([UInt8](data.suffix(4)), [1, 1, 60, 1])
    }

    func testRoundTripWholeBody() throws {
        let frames = [Data([0xAA]), Data(repeating: 0xBB, count: 200), Data([0xCC, 0xCD])]
        let data = try body(frames: frames, eomSeq: 3)
        var decoder = TxnStreamDecoder()
        let events = try decoder.feed(data)
        XCTAssertEqual(events, [
            .header(StreamHeader()),
            .frame(seq: 0, payload: frames[0]),
            .frame(seq: 1, payload: frames[1]),
            .frame(seq: 2, payload: frames[2]),
            .end(seq: 3),
        ])
        XCTAssertTrue(decoder.isComplete)
    }

    func testDecodesAcrossArbitrarySplits() throws {
        let frames = [Data([0x01]), Data(repeating: 0x02, count: 99), Data([0x03])]
        let data = try body(frames: frames, eomSeq: 3)
        // Feed one byte at a time — the harshest chunking TCP could produce.
        var decoder = TxnStreamDecoder()
        var events: [TxnStreamDecoder.Event] = []
        for byte in data {
            events.append(contentsOf: try decoder.feed(Data([byte])))
        }
        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(events.last, .end(seq: 3))
    }

    func testDiscardsResumeOverlap() throws {
        // Stream carries frames 0,1 then a resume overlap re-sends 1 before 2.
        var data = TxnStreamEncoder.header(StreamHeader())
        data.append(try TxnStreamEncoder.frameRecord(seq: 0, payload: Data([0x00])))
        data.append(try TxnStreamEncoder.frameRecord(seq: 1, payload: Data([0x01])))
        data.append(try TxnStreamEncoder.frameRecord(seq: 1, payload: Data([0x01])))
        data.append(try TxnStreamEncoder.frameRecord(seq: 2, payload: Data([0x02])))
        var decoder = TxnStreamDecoder()
        let events = try decoder.feed(data)
        XCTAssertEqual(events.filter {
            if case .frame = $0 { return true } else { return false }
        }.count, 3)
    }

    func testFromSeqStartsMidStream() throws {
        var data = TxnStreamEncoder.header(StreamHeader())
        data.append(try TxnStreamEncoder.frameRecord(seq: 40, payload: Data([0x28])))
        data.append(try TxnStreamEncoder.frameRecord(seq: 41, payload: Data([0x29])))
        var decoder = TxnStreamDecoder(firstSeq: 40)
        let events = try decoder.feed(data)
        XCTAssertEqual(events, [
            .header(StreamHeader()),
            .frame(seq: 40, payload: Data([0x28])),
            .frame(seq: 41, payload: Data([0x29])),
        ])
    }

    func testRejectsBadMagic() {
        var decoder = TxnStreamDecoder()
        XCTAssertThrowsError(try decoder.feed(Data("XXXXABCD".utf8))) {
            XCTAssertEqual($0 as? TxnStreamError, .badMagic)
        }
    }

    func testRejectsUnknownVersion() {
        var data = Data()
        data.appendLE(StreamHeader.magic)
        data.append(contentsOf: [9, 1, 60, 1])
        var decoder = TxnStreamDecoder()
        XCTAssertThrowsError(try decoder.feed(data)) {
            XCTAssertEqual($0 as? TxnStreamError, .unsupportedVersion(9))
        }
    }

    func testRejectsSequenceGap() throws {
        var data = TxnStreamEncoder.header(StreamHeader())
        data.append(try TxnStreamEncoder.frameRecord(seq: 0, payload: Data([0x00])))
        data.append(try TxnStreamEncoder.frameRecord(seq: 2, payload: Data([0x02])))
        var decoder = TxnStreamDecoder()
        XCTAssertThrowsError(try decoder.feed(data)) {
            XCTAssertEqual($0 as? TxnStreamError, .sequenceGap(expected: 1, got: 2))
        }
    }

    func testRejectsDataAfterEnd() throws {
        var data = try body(frames: [Data([0x00])], eomSeq: 1)
        data.append(Data([0xFF]))
        var decoder = TxnStreamDecoder()
        XCTAssertThrowsError(try decoder.feed(data)) {
            XCTAssertEqual($0 as? TxnStreamError, .dataAfterEnd)
        }
    }

    func testEncoderRejectsOversizedPayload() {
        XCTAssertThrowsError(try TxnStreamEncoder.frameRecord(
            seq: 0, payload: Data(repeating: 0, count: 1276)))
        XCTAssertNoThrow(try TxnStreamEncoder.frameRecord(
            seq: 0, payload: Data(repeating: 0, count: 1275)))
    }

    func testDecoderRejectsOversizedLength() {
        var data = TxnStreamEncoder.header(StreamHeader())
        data.appendLE(UInt32(0))
        data.appendLE(UInt16(1276))
        var decoder = TxnStreamDecoder()
        XCTAssertThrowsError(try decoder.feed(data)) {
            XCTAssertEqual($0 as? TxnStreamError, .payloadTooLong(1276))
        }
    }
}
