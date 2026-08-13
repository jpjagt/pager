import Foundation

/// Receiver-side loudness normalization (CLIENT.md "Audio levels"): level
/// every message toward `VoiceConfig.playoutTargetDb`, defensively — sender
/// capture varies by tens of dB, old messages replay forever, and old
/// firmware is effectively permanent. Runs on decoded PCM, so it costs a
/// multiplication and nothing on the wire.
///
/// One instance per message (senders differ; the gain must not leak across).
/// Streaming, zero lookahead: the first voiced frame sets the level estimate
/// outright and is itself leveled — equivalent in effect to measuring the
/// buffered prefix, since the prefix's loudness is dominated by its first
/// voiced audio — after which the estimate tracks slowly, so a deliberate
/// whisper-to-shout stays dynamic. Sub-gate frames (room tone, breath) are
/// passed through at the current gain untouched by the tracker: silence is
/// never what we level to, and before any voiced frame the gain is unity so
/// leading room tone is never boosted. A soft-knee limiter after the gain
/// stage keeps a boosted-then-loud passage from clipping.
public struct PlayoutNormalizer {
    private var levelDb: Double?

    public init() {}

    public mutating func process(_ pcm: [Int16]) -> [Int16] {
        let rms = Self.rmsDb(pcm)
        if rms > VoiceConfig.playoutGateDb {
            if let level = levelDb {
                levelDb = level + VoiceConfig.playoutLevelAlpha * (rms - level)
            } else {
                levelDb = rms
            }
        }
        guard let level = levelDb else { return pcm }
        let gainDb = min(VoiceConfig.playoutMaxBoostDb,
                         max(-VoiceConfig.playoutMaxCutDb,
                             VoiceConfig.playoutTargetDb - level))
        let gain = pow(10, gainDb / 20)
        return pcm.map { Self.limit(Double($0) / 32768 * gain) }
    }

    private static func rmsDb(_ pcm: [Int16]) -> Double {
        guard !pcm.isEmpty else { return -Double.infinity }
        let meanSquare = pcm.reduce(0.0) { $0 + Double($1) * Double($1) }
            / Double(pcm.count)
        guard meanSquare > 0 else { return -Double.infinity }
        return 20 * log10(meanSquare.squareRoot() / 32768)
    }

    /// Soft-knee limiter: linear below the knee, tanh-compressed above it,
    /// asymptotic to the ceiling — samples can never wrap or flip sign.
    private static func limit(_ x: Double) -> Int16 {
        let knee = 0.85, ceiling = 0.999
        let magnitude = abs(x)
        let limited = magnitude <= knee
            ? magnitude
            : knee + (ceiling - knee) * tanh((magnitude - knee) / (ceiling - knee))
        return Int16((x < 0 ? -limited : limited) * 32767)
    }
}
