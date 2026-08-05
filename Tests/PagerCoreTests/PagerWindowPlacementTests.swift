import XCTest
@testable import PagerCore

final class PagerWindowPlacementTests: XCTestCase {
    let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let size = CGSize(width: 220, height: 320)

    func testNoOccupiedAnchorsTopRightInset() {
        let frame = PagerWindowPlacement.frame(size: size, in: visibleFrame, avoiding: [])
        XCTAssertEqual(frame.size, size)
        // top-right of visibleFrame, inset by a sensible margin (not flush against the edge).
        XCTAssertLessThan(frame.maxX, visibleFrame.maxX)
        XCTAssertGreaterThan(frame.maxX, visibleFrame.maxX - 100)
        XCTAssertLessThan(frame.maxY, visibleFrame.maxY)
        XCTAssertGreaterThan(frame.maxY, visibleFrame.maxY - 100)
    }

    func testAvoidsSingleOccupiedRectAtTopRight() {
        let topRight = PagerWindowPlacement.frame(size: size, in: visibleFrame, avoiding: [])
        let frame = PagerWindowPlacement.frame(size: size, in: visibleFrame, avoiding: [topRight])
        XCTAssertFalse(frame.intersects(topRight))
        XCTAssertTrue(visibleFrame.contains(frame))
    }

    func testResultAlwaysWithinVisibleFrameEvenWhenScreenIsFull() {
        // Tile the entire screen with occupied rects so avoidance must fail
        // and the fallback path kicks in.
        var occupied: [CGRect] = []
        var y = visibleFrame.minY
        while y < visibleFrame.maxY {
            var x = visibleFrame.minX
            while x < visibleFrame.maxX {
                occupied.append(CGRect(x: x, y: y, width: size.width, height: size.height))
                x += size.width
            }
            y += size.height
        }

        let frame = PagerWindowPlacement.frame(size: size, in: visibleFrame, avoiding: occupied)
        XCTAssertTrue(visibleFrame.contains(frame), "fallback frame \(frame) escaped visibleFrame \(visibleFrame)")
    }

    /// The regression this file previously could not catch: the fallback used
    /// to derive its cascade index from two compile-time constants, so every
    /// overflow window landed on the identical anchor and only the topmost one
    /// was clickable. `contains` alone passes for a stack of identical frames —
    /// distinctness is the property that matters.
    func testFallbackCascadesToDistinctFramesWhenScreenIsFull() {
        let full = tiledOccupied()
        var frames: [CGRect] = []
        // Each successive overflow window sees one more pager already open.
        for extra in 0..<8 {
            let occupied = full + Array(repeating: full[0], count: extra)
            let frame = PagerWindowPlacement.frame(size: size, in: visibleFrame, avoiding: occupied)
            XCTAssertTrue(visibleFrame.contains(frame), "fallback frame \(frame) escaped \(visibleFrame)")
            frames.append(frame)
        }
        XCTAssertEqual(Set(frames.map { "\($0)" }).count, frames.count,
                       "overflow windows stacked on the same anchor: \(frames)")
    }

    func testFallbackStaysInsideEvenOnAScreenBarelyBiggerThanTheDevice() {
        // No room to cascade: every slot must still be the (single) in-frame one.
        let tight = CGRect(x: 10, y: 20, width: size.width + 8, height: size.height + 8)
        let full = [CGRect(x: 10, y: 20, width: 1000, height: 1000)]
        for extra in 0..<5 {
            let occupied = full + Array(repeating: full[0], count: extra)
            let frame = PagerWindowPlacement.frame(size: size, in: tight, avoiding: occupied)
            XCTAssertTrue(tight.contains(frame), "frame \(frame) escaped tight frame \(tight)")
        }
    }

    // MARK: - clamp

    func testClampLeavesAnAlreadyContainedRectAlone() {
        let rect = CGRect(x: 200, y: 300, width: 220, height: 320)
        XCTAssertEqual(PagerWindowPlacement.clamp(rect, in: visibleFrame), rect)
    }

    func testClampPushesAGrownDeviceBackAboveTheBottomEdge() {
        // Parked low with a one-line message, then an image lands: the device
        // grows downward and its key row falls off the bottom of the screen.
        let grown = CGRect(x: 900, y: -270, width: 220, height: 380)
        let clamped = PagerWindowPlacement.clamp(grown, in: visibleFrame)
        XCTAssertTrue(visibleFrame.contains(clamped))
        XCTAssertEqual(clamped.minY, visibleFrame.minY)
        XCTAssertEqual(clamped.minX, grown.minX) // horizontally untouched
        XCTAssertEqual(clamped.size, grown.size)
    }

    func testClampPullsARectRememberedOnADetachedDisplayFullyOnScreen() {
        // Overlaps the built-in screen by a few points — `intersects` was true,
        // which is exactly why containment is the test that matters.
        let stray = CGRect(x: 1435, y: 895, width: 220, height: 320)
        let clamped = PagerWindowPlacement.clamp(stray, in: visibleFrame)
        XCTAssertTrue(visibleFrame.contains(clamped))
        XCTAssertEqual(clamped.maxX, visibleFrame.maxX)
        XCTAssertEqual(clamped.maxY, visibleFrame.maxY)
    }

    func testClampPinsAnOversizedRectSoTheKeyRowStaysReachable() {
        let tall = CGRect(x: -50, y: -100, width: 2000, height: 1200)
        let clamped = PagerWindowPlacement.clamp(tall, in: visibleFrame)
        XCTAssertEqual(clamped.minX, visibleFrame.minX)
        XCTAssertEqual(clamped.minY, visibleFrame.minY) // bottom edge = the keys
        XCTAssertEqual(clamped.size, tall.size)
    }

    func testClampRespectsANonZeroOriginVisibleFrame() {
        let shifted = CGRect(x: -1440, y: 200, width: 1440, height: 900)
        let clamped = PagerWindowPlacement.clamp(
            CGRect(x: -2000, y: 0, width: 220, height: 320), in: shifted)
        XCTAssertTrue(shifted.contains(clamped))
        XCTAssertEqual(clamped.origin, CGPoint(x: shifted.minX, y: shifted.minY))
    }

    /// Tiles `visibleFrame` so no candidate the stepping search tries is free.
    private func tiledOccupied() -> [CGRect] {
        var occupied: [CGRect] = []
        var y = visibleFrame.minY
        while y < visibleFrame.maxY {
            var x = visibleFrame.minX
            while x < visibleFrame.maxX {
                occupied.append(CGRect(x: x, y: y, width: size.width, height: size.height))
                x += size.width
            }
            y += size.height
        }
        return occupied
    }

    func testReturnedSizeAlwaysEqualsRequestedSize() {
        let occupied = [CGRect(x: 1000, y: 500, width: 220, height: 320)]
        let frame = PagerWindowPlacement.frame(size: size, in: visibleFrame, avoiding: occupied)
        XCTAssertEqual(frame.size, size)
    }

    func testRespectsNonZeroOriginVisibleFrame() {
        // Multi-monitor: a display whose visibleFrame does not start at .zero.
        let shiftedFrame = CGRect(x: -1440, y: 200, width: 1440, height: 900)
        let frame = PagerWindowPlacement.frame(size: size, in: shiftedFrame, avoiding: [])
        XCTAssertEqual(frame.size, size)
        XCTAssertTrue(shiftedFrame.contains(frame), "frame \(frame) not inside shiftedFrame \(shiftedFrame)")
        // Anchored top-right of the shifted frame, not at absolute-zero coordinates.
        XCTAssertLessThan(frame.maxX, shiftedFrame.maxX)
        XCTAssertGreaterThan(frame.maxX, shiftedFrame.maxX - 100)
    }

    func testNeverLoopsForeverAndStaysInsideWithDenseOccupied() {
        // A dense, adversarial set of occupied rects covering most of the
        // screen with fine-grained overlap — the loop must still terminate
        // and the result must remain inside visibleFrame.
        var occupied: [CGRect] = []
        var y = visibleFrame.minY
        while y < visibleFrame.maxY {
            occupied.append(CGRect(x: visibleFrame.minX, y: y, width: visibleFrame.width, height: 10))
            y += 5
        }
        let frame = PagerWindowPlacement.frame(size: size, in: visibleFrame, avoiding: occupied)
        XCTAssertTrue(visibleFrame.contains(frame))
    }
}
