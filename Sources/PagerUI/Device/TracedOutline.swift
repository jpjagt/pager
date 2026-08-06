import SwiftUI

/// One cubic Bézier segment in design space.
///
/// "Design space" is the coordinate system the outline was traced in (the
/// SVG's viewBox), not points. Everything in this file works in design units
/// and only converts to the render rect at the very end, so the traced
/// numbers in `PagerOutlines` stay readable against the original SVG.
struct Cubic: Equatable {
    var p0: CGPoint
    var c1: CGPoint
    var c2: CGPoint
    var p1: CGPoint

    func point(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p1.x,
                       y: a * p0.y + b * c1.y + c * c2.y + d * p1.y)
    }

    /// dx/dt. Zero exactly at the segment's horizontal extremes, which is the
    /// whole reason this type exists — see `TracedOutline.apexes`.
    func dx(at t: CGFloat) -> CGFloat {
        let u = 1 - t
        return 3 * (u * u * (c1.x - p0.x) + 2 * u * t * (c2.x - c1.x) + t * t * (p1.x - c2.x))
    }

    /// Parameters in (0, 1) where dx/dt == 0 — i.e. where this segment is at
    /// its leftmost or rightmost. Solves the quadratic
    /// `(d0 − 2d1 + d2)t² + 2(d1 − d0)t + d0 = 0` for the control-point
    /// differences `d0/d1/d2`; the degenerate linear case is handled too
    /// because a traced segment can easily have collinear x-controls.
    var interiorXExtrema: [CGFloat] {
        let d0 = c1.x - p0.x, d1 = c2.x - c1.x, d2 = p1.x - c2.x
        let a = d0 - 2 * d1 + d2, b = 2 * (d1 - d0), c = d0

        if abs(a) < 1e-12 {
            guard abs(b) > 1e-12 else { return [] }
            let t = -c / b
            return (t > 0 && t < 1) ? [t] : []
        }
        let disc = b * b - 4 * a * c
        guard disc >= 0 else { return [] }
        let root = disc.squareRoot()
        return [(-b + root) / (2 * a), (-b - root) / (2 * a)].filter { $0 > 0 && $0 < 1 }
    }

    /// de Casteljau subdivision — exact, so splitting never moves the curve.
    func split(at t: CGFloat) -> (Cubic, Cubic) {
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        let a = mid(p0, c1), b = mid(c1, c2), c = mid(c2, p1)
        let d = mid(a, b), e = mid(b, c)
        let f = mid(d, e)
        return (Cubic(p0: p0, c1: a, c2: d, p1: f), Cubic(p0: f, c1: e, c2: c, p1: p1))
    }

    func offsetBy(dy: CGFloat) -> Cubic {
        func shift(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: p.y + dy) }
        return Cubic(p0: shift(p0), c1: shift(c1), c2: shift(c2), p1: shift(p1))
    }
}

/// A closed outline traced in a fixed design space that grows vertically by
/// inserting a straight wall at each side's **widest point**.
///
/// Why the widest point specifically: `dx/dt == 0` there, so the curve's
/// tangent is vertical. That is exactly the condition for a vertical wall to
/// join both halves without a kink. Split anywhere else and the insert shows
/// as a corner. So the split location isn't a tuned constant — it's solved
/// from the path, which also means re-tracing the art in Figma needs no
/// manual work beyond pasting new numbers.
///
/// The shape is cut into a rigid top cap and a rigid bottom cap at those two
/// points. Growth translates the bottom cap down and spans the gap with two
/// vertical lines; every traced control point is otherwise untouched, so any
/// deliberate asymmetry in the trace renders identically at every height.
///
/// Stretch is derived from the rect rather than passed in, which keeps this a
/// plain `Shape` usable with `fill`, `strokeBorder` and `clipShape`. Several
/// outlines drawn into the same rect therefore get the *same* delta, which is
/// what keeps the case, the faceplate and the screen nested as the device
/// grows — there is only one deformation and they are all subject to it.
public struct TracedOutline: Shape, InsettableShape {
    public let designSize: CGSize

    /// Rigid segments above the two apexes, in path order. Ends where
    /// `bottomCap` begins.
    private let topCap: [Cubic]
    /// Rigid segments below the two apexes, in path order. Ends where
    /// `topCap` begins.
    private let bottomCap: [Cubic]

    private var insetAmount: CGFloat = 0

    /// `segments` must form a closed loop in design space (the last segment's
    /// end point is the first's start point). Apexes are solved here, once.
    init(designSize: CGSize, segments: [Cubic]) {
        self.designSize = designSize
        let (top, bottom) = Self.caps(of: segments)
        self.topCap = top
        self.bottomCap = bottom
    }

    /// Splits the closed loop at its leftmost and rightmost points and returns
    /// the two arcs, top first. Which arc is "top" is decided by mean y rather
    /// than assuming a winding direction, so a re-traced path that happens to
    /// run the other way around still works.
    private static func caps(of segments: [Cubic]) -> (top: [Cubic], bottom: [Cubic]) {
        guard segments.count > 1 else { return (segments, []) }

        // Candidate extremes: every segment boundary plus every interior
        // dx/dt == 0 root.
        var minCandidate = (x: CGFloat.infinity, index: 0, t: CGFloat(0))
        var maxCandidate = (x: -CGFloat.infinity, index: 0, t: CGFloat(0))
        for (index, segment) in segments.enumerated() {
            for t in [0] + segment.interiorXExtrema {
                let x = segment.point(at: t).x
                if x < minCandidate.x { minCandidate = (x, index, t) }
                if x > maxCandidate.x { maxCandidate = (x, index, t) }
            }
        }

        // A root landing on a knot (outer-case's left apex solves to
        // t = 0.999998) must snap, or subdivision leaves a zero-length sliver
        // segment that later trips the "starts where the other ends" chaining.
        func snapped(_ candidate: (x: CGFloat, index: Int, t: CGFloat)) -> (index: Int, t: CGFloat) {
            if candidate.t < 1e-4 { return (candidate.index, 0) }
            if candidate.t > 1 - 1e-4 { return ((candidate.index + 1) % segments.count, 0) }
            return (candidate.index, candidate.t)
        }
        let first = snapped(minCandidate), second = snapped(maxCandidate)

        // Subdivide so both apexes are segment boundaries. Higher index first,
        // so splitting the lower one doesn't shift the higher one's index.
        var working = segments
        var boundaries: [Int] = []
        for split in [first, second].sorted(by: { $0.index > $1.index }) {
            if split.t == 0 {
                boundaries.append(split.index)
            } else {
                let (head, tail) = working[split.index].split(at: split.t)
                working[split.index] = head
                working.insert(tail, at: split.index + 1)
                boundaries.append(split.index + 1)
                // An earlier-recorded boundary sitting after this insert moves.
                boundaries = boundaries.map { $0 > split.index + 1 ? $0 + 1 : $0 }
            }
        }
        boundaries.sort()
        guard boundaries.count == 2, boundaries[0] != boundaries[1] else { return (working, []) }

        let arcA = Array(working[boundaries[0]..<boundaries[1]])
        let arcB = Array(working[boundaries[1]...] + working[..<boundaries[0]])

        func meanY(_ arc: [Cubic]) -> CGFloat {
            guard !arc.isEmpty else { return .infinity }
            return arc.reduce(0) { $0 + $1.p0.y } / CGFloat(arc.count)
        }
        return meanY(arcA) < meanY(arcB) ? (arcA, arcB) : (arcB, arcA)
    }

    public func inset(by amount: CGFloat) -> TracedOutline {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    /// Design-space height the rect implies, and the stretch that follows.
    /// Never negative: below the natural height the outline stops shrinking,
    /// which is why `PagerDeviceView` floors the device at its natural size.
    func stretch(in rect: CGRect) -> (scale: CGFloat, delta: CGFloat) {
        let scale = rect.width / designSize.width
        guard scale > 0 else { return (1, 0) }
        return (scale, max(0, rect.height / scale - designSize.height))
    }

    public func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard !topCap.isEmpty, !bottomCap.isEmpty else { return Path() }
        let (scale, delta) = stretch(in: r)

        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: r.minX + p.x * scale, y: r.minY + p.y * scale)
        }
        func add(_ segment: Cubic, to path: inout Path) {
            path.addCurve(to: map(segment.p1), control1: map(segment.c1), control2: map(segment.c2))
        }

        var path = Path()
        path.move(to: map(topCap[0].p0))
        for segment in topCap { add(segment, to: &path) }

        // Down the wall on one side, along the translated bottom cap, back up
        // the wall on the other. Both walls are vertical by construction.
        path.addLine(to: map(bottomCap[0].p0.offsetBy(dy: delta)))
        for segment in bottomCap { add(segment.offsetBy(dy: delta), to: &path) }
        path.addLine(to: map(topCap[0].p0))
        path.closeSubpath()
        return path
    }
}

/// A traced closed path that does **not** stretch — it just normalizes its own
/// design-space bounds onto whatever rect it's given.
///
/// This is what the key shapes use. Keys live entirely in the outline's rigid
/// bottom cap, so they never need the wall insert; they only need to be a
/// `Shape` so the existing `PagerKeyFace` gloss stack and `RockerGeometry`'s
/// wedge intersection keep working unchanged.
public struct TracedShape: Shape {
    /// Tight bounds of the traced curve (computed offline, including curve
    /// extrema — not the control polygon's bounds, which are looser).
    public let designBounds: CGRect
    private let segments: [Cubic]

    init(designBounds: CGRect, segments: [Cubic]) {
        self.designBounds = designBounds
        self.segments = segments
    }

    public func path(in rect: CGRect) -> Path {
        guard !segments.isEmpty, designBounds.width > 0, designBounds.height > 0 else { return Path() }
        let sx = rect.width / designBounds.width
        let sy = rect.height / designBounds.height

        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + (p.x - designBounds.minX) * sx,
                    y: rect.minY + (p.y - designBounds.minY) * sy)
        }

        var path = Path()
        path.move(to: map(segments[0].p0))
        for segment in segments {
            path.addCurve(to: map(segment.p1), control1: map(segment.c1), control2: map(segment.c2))
        }
        path.closeSubpath()
        return path
    }
}

extension CGPoint {
    func offsetBy(dy: CGFloat) -> CGPoint { CGPoint(x: x, y: y + dy) }
}
