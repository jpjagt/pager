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
