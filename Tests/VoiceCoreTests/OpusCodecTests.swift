import XCTest
@testable import VoiceCore

final class OpusCodecTests: XCTestCase {
    private func sineFrame(_ codec: OpusCodec, hz: Double = 440,
                           amplitude: Double = 8000, phase: Double = 0) -> [Int16] {
        (0 ..< codec.samplesPerFrame).map { i in
            Int16(amplitude * sin(phase + 2 * .pi * hz * Double(i)
                                  / Double(VoiceConfig.sampleRate)))
        }
    }

    func testSamplesPerFrameMatchesProfile() throws {
        let codec = try LibOpusCodec()
        XCTAssertEqual(codec.samplesPerFrame, 960) // 16 kHz × 60 ms
    }

    func testEncodedFramesFitTheWireFormat() throws {
        let codec = try LibOpusCodec()
        for i in 0 ..< 10 {
            let frame = try codec.encode(sineFrame(codec, phase: Double(i)))
            XCTAssertGreaterThanOrEqual(frame.count, 1)
            XCTAssertLessThanOrEqual(frame.count, TxnStreamEncoder.maxPayloadLength)
        }
    }

    func testRoundTripPreservesSignalEnergy() throws {
        let encoderSide = try LibOpusCodec()
        let decoderSide = try LibOpusCodec()
        // Warm up past the codec's initial convergence, then measure.
        var decoded: [Int16] = []
        for i in 0 ..< 20 {
            let pcm = sineFrame(encoderSide, phase: Double(i))
            decoded = try decoderSide.decode(try encoderSide.encode(pcm))
        }
        XCTAssertEqual(decoded.count, 960)
        let energy = decoded.reduce(0.0) { $0 + Double($1) * Double($1) }
            / Double(decoded.count)
        XCTAssertGreaterThan(energy.squareRoot(), 1000, "signal should survive the codec")
    }

    func testSilenceEncodesSmall() throws {
        let codec = try LibOpusCodec()
        var last = Data()
        for _ in 0 ..< 5 {
            last = try codec.encode([Int16](repeating: 0, count: codec.samplesPerFrame))
        }
        XCTAssertLessThan(last.count, 400, "60 ms of silence should not need many bytes")
    }

    func testWrongFrameSizeThrows() throws {
        let codec = try LibOpusCodec()
        XCTAssertThrowsError(try codec.encode([Int16](repeating: 0, count: 100))) {
            XCTAssertEqual($0 as? OpusError, .wrongFrameSize(got: 100, want: 960))
        }
    }

    func testGarbageFrameFailsCleanly() throws {
        let codec = try LibOpusCodec()
        // A syntactically hopeless frame must throw, not crash. (Opus can
        // decode surprisingly much garbage "successfully" — either outcome
        // is fine, crashing is not.)
        _ = try? codec.decode(Data([0xFF, 0xFE, 0x00, 0x01]))
    }
}
