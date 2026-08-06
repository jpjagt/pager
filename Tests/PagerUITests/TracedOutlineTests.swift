import XCTest
import SwiftUI
@testable import PagerUI

/// The geometry behind the device silhouette. This is the one part of the
/// skin that is real math rather than presentation, so it's the part that
/// gets tested: everything else in `PagerUI` is verified by looking at a
/// `design-preview` render.
final class TracedOutlineTests: XCTestCase {

    /// The case's final segment — the right flank, which bulges out past both
    /// its endpoints and so carries an interior widest point.
    private let rightFlank = Cubic(
        p0: CGPoint(x: 481.512, y: 168.135),
        c1: CGPoint(x: 485.289, y: 97.4614),
        c2: CGPoint(x: 485.783, y: 34.3006),
        p1: CGPoint(x: 469.324, y: 17.8419))

    // MARK: - Cubic

    func testInteriorXExtremaFindsTheSingleRootOnTheRightFlank() {
        let roots = rightFlank.interiorXExtrema
        XCTAssertEqual(roots.count, 1, "the right flank bulges once, so exactly one root lies in (0,1)")
        XCTAssertEqual(roots[0], 0.337745, accuracy: 1e-5)
    }

    /// The split point must be a *vertical tangent*, which is the entire
    /// justification for splitting there: it's the only place a straight
    /// vertical wall can be inserted without producing a visible kink.
    func testTheWidestPointHasAVerticalTangent() {
        let t = rightFlank.interiorXExtrema[0]
        XCTAssertEqual(rightFlank.dx(at: t), 0, accuracy: 1e-6, "dx/dt must vanish at the widest point")
        XCTAssertEqual(rightFlank.point(at: t).x, 483.689, accuracy: 1e-3)
        XCTAssertEqual(rightFlank.point(at: t).y, 100.607, accuracy: 1e-3)
    }

    /// de Casteljau is exact, so subdividing must not move the curve by so
    /// much as a rounding error — otherwise re-tracing the art would silently
    /// change the silhouette.
    func testSplitReproducesTheOriginalCurveExactly() {
        let s: CGFloat = 0.3
        let (head, tail) = rightFlank.split(at: s)
        for i in 0...20 {
            let t = CGFloat(i) / 20
            let onHead = head.point(at: t)
            let expectedHead = rightFlank.point(at: t * s)
            XCTAssertEqual(onHead.x, expectedHead.x, accuracy: 1e-9)
            XCTAssertEqual(onHead.y, expectedHead.y, accuracy: 1e-9)

            let onTail = tail.point(at: t)
            let expectedTail = rightFlank.point(at: s + t * (1 - s))
            XCTAssertEqual(onTail.x, expectedTail.x, accuracy: 1e-9)
            XCTAssertEqual(onTail.y, expectedTail.y, accuracy: 1e-9)
        }
    }

    // MARK: - TracedOutline

    private var naturalRect: CGRect {
        CGRect(origin: .zero, size: PagerOutlines.designSize)
    }

    func testAtNaturalSizeTheOutlineMatchesTheTracedBounds() {
        let box = PagerOutlines.outerCase.path(in: naturalRect).boundingRect
        XCTAssertEqual(box.minX, 0.500, accuracy: 0.01)
        XCTAssertEqual(box.maxX, 483.689, accuracy: 0.01)
        XCTAssertEqual(box.minY, 0.500, accuracy: 0.01)
        XCTAssertEqual(box.maxY, 281.048, accuracy: 0.01)
    }

    /// Growth is entirely absorbed by the two walls: the shape gets taller by
    /// exactly the amount asked for, no more and no less.
    func testStretchAddsExactlyTheRequestedHeight() {
        let stretched = naturalRect.insetBy(dx: 0, dy: -50).offsetBy(dx: 0, dy: 50) // +100 tall, same top
        let natural = PagerOutlines.outerCase.path(in: naturalRect).boundingRect
        let grown = PagerOutlines.outerCase.path(in: stretched).boundingRect
        XCTAssertEqual(grown.height - natural.height, 100, accuracy: 0.01)
    }

    /// The top cap is rigid. Whatever the device height, the top edge is the
    /// traced top edge — which is what pins the wordmark and the close key.
    func testTheTopCapDoesNotMoveWhenTheDeviceGrows() {
        for extra in [CGFloat(0), 40, 100, 250] {
            let rect = CGRect(x: 0, y: 0, width: 485, height: 282 + extra)
            let box = PagerOutlines.outerCase.path(in: rect).boundingRect
            XCTAssertEqual(box.minY, 0.500, accuracy: 0.01, "top edge moved at +\(extra)")
        }
    }

    /// Both inserted walls must be vertical and sit at the outline's extreme
    /// x. A non-vertical wall would mean the split landed somewhere other than
    /// the widest point.
    func testTheInsertedWallsAreVerticalAndAtTheWidestPoints() {
        let rect = CGRect(x: 0, y: 0, width: 485, height: 382)
        var walls: [(from: CGPoint, to: CGPoint)] = []
        var cursor = CGPoint.zero
        PagerOutlines.outerCase.path(in: rect).forEach { element in
            switch element {
            case .move(let to): cursor = to
            case .line(let to): walls.append((cursor, to)); cursor = to
            case .curve(let to, _, _): cursor = to
            case .quadCurve(let to, _): cursor = to
            case .closeSubpath: break
            }
        }

        XCTAssertEqual(walls.count, 2, "exactly two walls — one per side")
        for wall in walls {
            XCTAssertEqual(wall.from.x, wall.to.x, accuracy: 1e-6, "wall is not vertical")
            XCTAssertEqual(abs(wall.to.y - wall.from.y), 100, accuracy: 0.01, "wall does not span the stretch")
        }
        let wallXs = walls.map(\.from.x).sorted()
        XCTAssertEqual(wallXs[0], 0.500, accuracy: 0.01, "left wall is not at the leftmost point")
        XCTAssertEqual(wallXs[1], 483.689, accuracy: 0.01, "right wall is not at the rightmost point")
    }

    /// The faceplate splits at its own apexes, ~13 design units away from the
    /// case's. That mismatch is deliberate and harmless — each wall is
    /// invisible at its own vertical tangent — but both shapes must still grow
    /// by the same total, or they'd drift apart as the device stretches.
    func testCaseAndFaceplateGrowByTheSameAmount() {
        let rect = CGRect(x: 0, y: 0, width: 485, height: 382)
        let caseGrowth = PagerOutlines.outerCase.path(in: rect).boundingRect.height
            - PagerOutlines.outerCase.path(in: naturalRect).boundingRect.height
        let faceplateGrowth = PagerOutlines.faceplate.path(in: rect).boundingRect.height
            - PagerOutlines.faceplate.path(in: naturalRect).boundingRect.height
        XCTAssertEqual(caseGrowth, 100, accuracy: 0.01)
        XCTAssertEqual(faceplateGrowth, 100, accuracy: 0.01)
    }

    func testFaceplateSplitsAtItsOwnApexes() {
        let rect = CGRect(x: 0, y: 0, width: 485, height: 382)
        var wallXs: [CGFloat] = []
        var cursor = CGPoint.zero
        PagerOutlines.faceplate.path(in: rect).forEach { element in
            switch element {
            case .move(let to): cursor = to
            case .line(let to): wallXs.append(cursor.x); cursor = to
            case .curve(let to, _, _): cursor = to
            case .quadCurve(let to, _): cursor = to
            case .closeSubpath: break
            }
        }
        XCTAssertEqual(wallXs.sorted().first ?? 0, 27.474, accuracy: 0.01)
        XCTAssertEqual(wallXs.sorted().last ?? 0, 460.134, accuracy: 0.01)
    }

    /// Below its natural height the outline stops shrinking rather than
    /// squashing — the floor `PagerDeviceView` relies on.
    func testTheOutlineNeverCompressesBelowItsNaturalHeight() {
        let squashed = CGRect(x: 0, y: 0, width: 485, height: 150)
        let box = PagerOutlines.outerCase.path(in: squashed).boundingRect
        XCTAssertEqual(box.height, 280.548, accuracy: 0.01, "outline compressed instead of holding its floor")
    }

    // MARK: - TracedShape

    func testKeyShapesNormalizeOntoWhateverRectTheyAreGiven() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 40)
        let box = PagerOutlines.rockerLeaf.path(in: rect).boundingRect
        XCTAssertEqual(box.minX, rect.minX, accuracy: 0.05)
        XCTAssertEqual(box.minY, rect.minY, accuracy: 0.05)
        XCTAssertEqual(box.width, rect.width, accuracy: 0.05)
        XCTAssertEqual(box.height, rect.height, accuracy: 0.05)
    }
}
