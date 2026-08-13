import XCTest
@testable import VoiceCore

final class PlayoutNormalizerTests: XCTestCase {
    private let samplesPerFrame = 960 // 60 ms at 16 kHz

    /// A sine frame whose RMS is `rmsDb` dBFS (0 dBFS = full-scale RMS).
    private func sineFrame(rmsDb: Double, hz: Double = 220) -> [Int16] {
        let amplitude = 32768.0 * pow(10, rmsDb / 20) * 2.0.squareRoot()
        return (0 ..< samplesPerFrame).map { i in
            let t = Double(i) / Double(VoiceConfig.sampleRate)
            return Int16(max(-32768, min(32767, amplitude * sin(2 * .pi * hz * t))))
        }
    }

    private func rmsDb(_ pcm: [Int16]) -> Double {
        let meanSquare = pcm.reduce(0.0) { $0 + Double($1) * Double($1) }
            / Double(pcm.count)
        return 20 * log10(meanSquare.squareRoot() / 32768)
    }

    func testSubGateFramesPassThroughUntouched() {
        var normalizer = PlayoutNormalizer()
        let silence = sineFrame(rmsDb: -66)
        XCTAssertEqual(normalizer.process(silence), silence,
                       "room tone below the gate must not be boosted")
    }

    func testQuietVoicedFrameIsBoostedToTargetImmediately() {
        var normalizer = PlayoutNormalizer()
        _ = normalizer.process(sineFrame(rmsDb: -66)) // leading silence
        let out = normalizer.process(sineFrame(rmsDb: -40))
        XCTAssertEqual(rmsDb(out), VoiceConfig.playoutTargetDb, accuracy: 1.5,
                       "first voiced frame sets the gain and is itself leveled")
    }

    func testLoudVoicedFrameIsAttenuatedToTarget() {
        var normalizer = PlayoutNormalizer()
        let out = normalizer.process(sineFrame(rmsDb: -8))
        XCTAssertEqual(rmsDb(out), VoiceConfig.playoutTargetDb, accuracy: 1.5)
    }

    func testBoostIsCapped() {
        var normalizer = PlayoutNormalizer()
        let out = normalizer.process(sineFrame(rmsDb: -52)) // needs +34 dB
        XCTAssertEqual(rmsDb(out), -52 + VoiceConfig.playoutMaxBoostDb,
                       accuracy: 1.5, "gain never exceeds the boost cap")
    }

    func testGainAdaptsSlowlyAfterConvergence() {
        var normalizer = PlayoutNormalizer()
        for _ in 0 ..< 10 { _ = normalizer.process(sineFrame(rmsDb: -40)) }
        // A suddenly-louder passage keeps (almost) the established gain —
        // it gets louder, rather than being re-leveled to target.
        let out = normalizer.process(sineFrame(rmsDb: -30))
        XCTAssertGreaterThan(rmsDb(out), -12,
                             "established +22 dB gain still applies")
        XCTAssertLessThan(rmsDb(out), -5, "minus a small adaptation step")
    }

    func testLimiterPreventsOverflowAndPreservesSign() {
        var normalizer = PlayoutNormalizer()
        for _ in 0 ..< 10 { _ = normalizer.process(sineFrame(rmsDb: -40)) }
        let loud = sineFrame(rmsDb: -6)
        let out = normalizer.process(loud) // ~10× gain on near-full-scale
        for (input, output) in zip(loud, out) {
            XCTAssertLessThanOrEqual(abs(Int(output)), 32767)
            if abs(input) > 100 {
                XCTAssertEqual(output.signum(), input.signum(),
                               "no wraparound: samples never flip sign")
            }
        }
        let peak = out.map { abs(Int($0)) }.max() ?? 0
        XCTAssertGreaterThan(peak, 25_000, "limited, not silenced")
    }
}
