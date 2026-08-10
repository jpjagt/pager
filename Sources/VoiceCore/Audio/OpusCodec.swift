import Foundation
import COpus

/// One frame in, one frame out — the protocol's fixed-duration frames make
/// the codec stateless from the caller's view. Real impl below; tests use
/// fakes so protocol logic never depends on codec behavior.
public protocol OpusCodec: Sendable {
    /// PCM samples per frame (16 kHz mono × 60 ms = 960).
    var samplesPerFrame: Int { get }
    func encode(_ pcm: [Int16]) throws -> Data
    func decode(_ frame: Data) throws -> [Int16]
}

public enum OpusError: Error, Equatable {
    case creationFailed(Int32)
    case codeFailed(Int32)
    case wrongFrameSize(got: Int, want: Int)
}

/// libopus (vendored, float build) at the uplink profile: 16 kHz mono,
/// 48 kbps (pendant spec §1.3 — headroom against server re-encoding).
public final class LibOpusCodec: OpusCodec, @unchecked Sendable {
    public let samplesPerFrame: Int
    private let encoder: OpaquePointer
    private let decoder: OpaquePointer
    /// libopus encoders/decoders are not thread-safe; all use goes through
    /// this lock so the codec can be shared across record/playout paths.
    private let lock = NSLock()

    public init(sampleRate: Int = VoiceConfig.sampleRate,
                frameMs: Int = VoiceConfig.frameMs,
                bitrate: Int = VoiceConfig.bitrate) throws {
        samplesPerFrame = sampleRate * frameMs / 1000
        var error: Int32 = 0
        guard let enc = opus_encoder_create(Int32(sampleRate), 1,
                                            OPUS_APPLICATION_VOIP, &error),
              error == OPUS_OK else {
            throw OpusError.creationFailed(error)
        }
        guard let dec = opus_decoder_create(Int32(sampleRate), 1, &error),
              error == OPUS_OK else {
            opus_encoder_destroy(enc)
            throw OpusError.creationFailed(error)
        }
        encoder = enc
        decoder = dec
        copus_encoder_set_bitrate(enc, Int32(bitrate))
    }

    deinit {
        opus_encoder_destroy(encoder)
        opus_decoder_destroy(decoder)
    }

    public func encode(_ pcm: [Int16]) throws -> Data {
        guard pcm.count == samplesPerFrame else {
            throw OpusError.wrongFrameSize(got: pcm.count, want: samplesPerFrame)
        }
        lock.lock()
        defer { lock.unlock() }
        var out = Data(count: TxnStreamEncoder.maxPayloadLength)
        let written = out.withUnsafeMutableBytes { outPtr in
            pcm.withUnsafeBufferPointer { pcmPtr in
                opus_encode(encoder, pcmPtr.baseAddress!, Int32(samplesPerFrame),
                            outPtr.bindMemory(to: UInt8.self).baseAddress!,
                            Int32(TxnStreamEncoder.maxPayloadLength))
            }
        }
        guard written > 0 else { throw OpusError.codeFailed(written) }
        return out.prefix(Int(written))
    }

    public func decode(_ frame: Data) throws -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        var pcm = [Int16](repeating: 0, count: samplesPerFrame)
        let decoded = pcm.withUnsafeMutableBufferPointer { pcmPtr in
            frame.withUnsafeBytes { framePtr in
                opus_decode(decoder, framePtr.bindMemory(to: UInt8.self).baseAddress,
                            Int32(frame.count), pcmPtr.baseAddress!,
                            Int32(samplesPerFrame), 0)
            }
        }
        guard decoded > 0 else { throw OpusError.codeFailed(decoded) }
        return Array(pcm.prefix(Int(decoded)))
    }
}
