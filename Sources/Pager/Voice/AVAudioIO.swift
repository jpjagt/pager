import AVFoundation
import VoiceCore

/// The real `AudioIO`: AVAudioEngine on both sides of the seam.
///
/// Capture taps the input node, converts to the codec profile (16 kHz mono
/// Int16) and delivers exact `samplesPerFrame` frames. Playback honors the
/// seam's pull contract: a main-actor timer at frame cadence asks `next()`
/// and schedules the returned PCM on a player node — pacing stays in
/// `PlayoutMachine`, the node just renders what it is handed.
///
/// `VoiceEngine` (the only caller) never runs capture and playback at once;
/// nothing here needs to re-check that.
@MainActor
final class AVAudioIO: AudioIO {
    private let sampleRate = Double(VoiceConfig.sampleRate)
    private let samplesPerFrame = VoiceConfig.sampleRate * VoiceConfig.frameMs / 1000

    private var captureEngine: AVAudioEngine?
    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var pullTimer: Timer?
    private var pcmCarry: [Int16] = []

    private lazy var codecFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
        channels: 1, interleaved: true)!
    private lazy var playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
        channels: 1, interleaved: false)!

    // MARK: - Capture

    func startCapture(onFrame: @escaping ([Int16]) -> Void) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // The sender's half of CLIENT.md "Audio levels": the OS
        // voice-processing capture path (tuned AGC + noise suppression) is
        // what puts a well-leveled ~-18 LUFS send on the wire instead of
        // raw input at whatever the mic gain happens to be. Best-effort —
        // some devices refuse, and plain capture still works, just quiet
        // (the receiver's playout normalizer picks up the slack). Must be
        // set before the tap: enabling changes the input format.
        try? input.setVoiceProcessingEnabled(true)
        if input.isVoiceProcessingEnabled {
            input.isVoiceProcessingAGCEnabled = true
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: codecFormat) else {
            throw OpusError.creationFailed(-1)
        }
        // With voice processing on, the input node reports a multichannel
        // format (processed mic on channel 0, echo-reference channels after
        // it); the converter's default many→mono downmix lands on the empty
        // channels and yields exact silence. Channel 0 is the mic — always.
        if inputFormat.channelCount > 1 {
            converter.channelMap = [0]
        }
        pcmCarry = []
        // ~50 ms per tap callback; the carry buffer re-slices to exact frames.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] buffer, _ in
            let ratio = self!.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let converted = AVAudioPCMBuffer(pcmFormat: self!.codecFormat,
                                                   frameCapacity: capacity) else { return }
            var fed = false
            converter.convert(to: converted, error: nil) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard let channel = converted.int16ChannelData?[0],
                  converted.frameLength > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channel,
                                                    count: Int(converted.frameLength)))
            Task { @MainActor [weak self] in
                guard let self, self.captureEngine === engine else { return }
                self.pcmCarry.append(contentsOf: samples)
                while self.pcmCarry.count >= self.samplesPerFrame {
                    let frame = Array(self.pcmCarry.prefix(self.samplesPerFrame))
                    self.pcmCarry.removeFirst(self.samplesPerFrame)
                    onFrame(frame)
                }
            }
        }
        engine.prepare()
        try engine.start()
        captureEngine = engine
    }

    func stopCapture() {
        captureEngine?.inputNode.removeTap(onBus: 0)
        captureEngine?.stop()
        captureEngine = nil
        pcmCarry = []
    }

    // MARK: - Playback

    func startPlayback(next: @escaping () -> [Int16]?) throws {
        stopPlayback()
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: playbackFormat)
        engine.prepare()
        try engine.start()
        node.play()
        playbackEngine = engine
        playerNode = node

        let interval = Double(VoiceConfig.frameMs) / 1000
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.playerNode === node else {
                    timer.invalidate()
                    return
                }
                guard let pcm = next() else { return } // silence this tick
                self.schedule(pcm, on: node)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pullTimer = timer
        // Prime immediately rather than waiting one interval.
        if let pcm = next() { schedule(pcm, on: node) }
    }

    private func schedule(_ pcm: [Int16], on node: AVAudioPlayerNode) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat,
                                            frameCapacity: AVAudioFrameCount(pcm.count)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(pcm.count)
        let channel = buffer.floatChannelData![0]
        for (index, sample) in pcm.enumerated() {
            channel[index] = Float(sample) / 32768
        }
        node.scheduleBuffer(buffer)
    }

    func stopPlayback() {
        pullTimer?.invalidate()
        pullTimer = nil
        playerNode?.stop()
        playerNode = nil
        playbackEngine?.stop()
        playbackEngine = nil
    }
}
