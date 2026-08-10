import Foundation

/// The one audio seam. The real implementation (AVAudioEngine, in the app)
/// and the test fake both promise the same contract:
///
/// - Capture delivers exactly `samplesPerFrame`-sized PCM frames, one per
///   frame interval, until stopped.
/// - Playback *pulls*: the render clock calls `next()` once per frame
///   interval and plays what it returns; nil renders silence. The pull model
///   is what lets `PlayoutMachine` own all pacing policy.
/// - Capture and playback are never active at once (pendant invariant #1) —
///   enforced by `VoiceEngine`, the seam's only caller, not re-checked here.
@MainActor
public protocol AudioIO: AnyObject {
    func startCapture(onFrame: @escaping ([Int16]) -> Void) throws
    func stopCapture()
    func startPlayback(next: @escaping () -> [Int16]?) throws
    func stopPlayback()
}
