import XCTest
@testable import VoiceCore

final class PlayoutMachineTests: XCTestCase {
    private func frame(_ n: UInt8) -> Data { Data([n]) }

    /// 60 ms frames, N_start 500 → 9 frames (540 ms) crosses the threshold.
    private func makeMachine() -> PlayoutMachine {
        PlayoutMachine(frameMs: 60, startThresholdMs: 500, resumeThresholdMs: 250)
    }

    func testStartsOnBufferThreshold() {
        var m = makeMachine()
        m.begin()
        for i in 0 ..< 8 {
            m.receive(frame(UInt8(i)))
            XCTAssertEqual(m.state, .buffering, "480 ms < 500 ms")
        }
        m.receive(frame(8))
        XCTAssertEqual(m.state, .playing)
        XCTAssertEqual(m.stats.startBufferMs, 540)
    }

    func testShortMessageStartsOnEOMBeforeThreshold() {
        var m = makeMachine()
        m.begin()
        m.receive(frame(0))
        m.receive(frame(1))
        XCTAssertEqual(m.state, .buffering)
        m.endOfMessage()
        XCTAssertEqual(m.state, .playing)
        XCTAssertEqual(m.nextFrame(), frame(0))
        XCTAssertEqual(m.nextFrame(), frame(1))
        XCTAssertEqual(m.state, .complete)
        XCTAssertEqual(m.stats.underruns, 0)
    }

    func testUnderrunPausesSilentlyAndRebuffersToResume() {
        var m = makeMachine()
        m.begin()
        for i in 0 ..< 9 { m.receive(frame(UInt8(i))) }
        for _ in 0 ..< 9 { XCTAssertNotNil(m.nextFrame()) }
        // Buffer dry, no EOM: clean pause, one underrun, no filler frames.
        XCTAssertNil(m.nextFrame())
        XCTAssertEqual(m.state, .paused)
        XCTAssertEqual(m.stats.underruns, 1)
        // 240 ms < N_resume 250 — still paused.
        for i in 9 ..< 13 { m.receive(frame(UInt8(i))) }
        XCTAssertEqual(m.state, .paused)
        m.receive(frame(13)) // 300 ms ≥ 250
        XCTAssertEqual(m.state, .playing)
        XCTAssertEqual(m.nextFrame(), frame(9))
    }

    func testEOMWhilePausedDrainsAndCompletes() {
        var m = makeMachine()
        m.begin()
        for i in 0 ..< 9 { m.receive(frame(UInt8(i))) }
        for _ in 0 ..< 9 { _ = m.nextFrame() }
        _ = m.nextFrame() // underrun → paused
        m.receive(frame(9))
        XCTAssertEqual(m.state, .paused, "60 ms < N_resume")
        m.endOfMessage()
        XCTAssertEqual(m.state, .playing, "EOM ends the wait")
        XCTAssertEqual(m.nextFrame(), frame(9))
        XCTAssertEqual(m.state, .complete)
    }

    func testArchivePlayStartsInstantlyAndNeverUnderruns() {
        var m = makeMachine()
        for i in 0 ..< 30 { m.receive(frame(UInt8(i))) } // all on disk already
        m.endOfMessage()
        m.begin()
        XCTAssertEqual(m.state, .playing)
        var played = 0
        while let _ = m.nextFrame() { played += 1 }
        XCTAssertEqual(played, 30)
        XCTAssertEqual(m.state, .complete)
        XCTAssertEqual(m.stats.underruns, 0)
    }

    func testNetworkOutrunningRealtimeJustGrowsTheBuffer() {
        var m = makeMachine()
        m.begin()
        for i in 0 ..< 100 { m.receive(frame(UInt8(i % 250))) }
        XCTAssertEqual(m.state, .playing)
        XCTAssertEqual(m.bufferedMs, 6000)
        _ = m.nextFrame()
        XCTAssertEqual(m.bufferedMs, 5940, "consumption is clock-paced, one per tick")
    }

    func testStopClearsEverything() {
        var m = makeMachine()
        m.begin()
        for i in 0 ..< 9 { m.receive(frame(UInt8(i))) }
        XCTAssertEqual(m.state, .playing)
        m.stop()
        XCTAssertEqual(m.state, .idle)
        XCTAssertNil(m.nextFrame())
        XCTAssertEqual(m.bufferedMs, 0)
    }

    func testMinBufferTracksChaseDepth() {
        var m = makeMachine()
        m.begin()
        for i in 0 ..< 9 { m.receive(frame(UInt8(i))) }
        _ = m.nextFrame()
        _ = m.nextFrame()
        m.receive(frame(9))
        XCTAssertEqual(m.stats.minBufferMs, 420)
        XCTAssertEqual(m.stats.startBufferMs, 540)
    }

    func testBeginIsIdempotentWhileActive() {
        var m = makeMachine()
        m.begin()
        for i in 0 ..< 9 { m.receive(frame(UInt8(i))) }
        m.begin() // a second tap mid-play is handled by the caller as stop;
                  // a stray begin must not reset the machine
        XCTAssertEqual(m.state, .playing)
        XCTAssertEqual(m.bufferedMs, 540)
    }
}
