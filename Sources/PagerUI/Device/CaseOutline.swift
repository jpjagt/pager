import SwiftUI

/// The moulded case silhouette: two long flat edges (top and bottom) joined
/// by a pair of squircle end caps.
///
/// A `RoundedRectangle` — even `.continuous` — can't express this shape,
/// because its corner is square: raising the radius enough to make the left
/// and right ends read as *moulded* also eats the flat top the reference
/// device has. Here the cap's horizontal and vertical reach are independent,
/// so the corner can be short-and-wide vertically (`capHeight` ≫ `capWidth`)
/// — the turn off the top edge happens quickly, then the curve takes its
/// time bowing down into the side. That asymmetry is what reads as "flat
/// top, round sides."
///
/// Each cap is one cubic whose tangent is horizontal where it leaves the top
/// or bottom edge and vertical where it meets the side, so the outline is G1
/// at every junction by construction — same guarantee (and same reason) as
/// `SmoothOutline` in `KeyShapes`. `flat` and `round` are the two handle
/// lengths as fractions of the cap's own spans: pushing both toward 1
/// squares the cap off, pulling them toward 0 rounds it into a lens; the
/// circular value is ≈0.55 for both.
public struct CaseOutline: Shape, InsettableShape {
    /// How far in from each side the cap reaches, in points.
    public var capWidth: CGFloat
    /// How far down from the top (and up from the bottom) the cap reaches.
    /// The straight side run is what's left over, so on a short device this
    /// clamps to half the height and the ends become continuous curves.
    public var capHeight: CGFloat
    public var flat: CGFloat
    public var round: CGFloat

    private var insetAmount: CGFloat = 0

    public init(capWidth: CGFloat = 38, capHeight: CGFloat = 70,
                flat: CGFloat = 0.42, round: CGFloat = 0.46) {
        self.capWidth = capWidth
        self.capHeight = capHeight
        self.flat = flat
        self.round = round
    }

    public func inset(by amount: CGFloat) -> CaseOutline {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    /// The horizontal inset of the outline at `y` points below the top edge
    /// (equivalently, above the bottom) for a device of height `height` —
    /// i.e. how much room the case steals from its own contents at that
    /// depth. `PagerShell` sizes its content insets off this rather than
    /// hard-coding a number that silently stops clearing the curve the next
    /// time the cap is retuned.
    public func inset(atDepth y: CGFloat, height: CGFloat = .infinity) -> CGFloat {
        let ch = min(capHeight, height / 2)
        guard y < ch, ch > 0, capWidth > 0 else { return 0 }
        // Walk the cap curve rather than solving it: 64 steps over a
        // ~40×58pt arc lands well inside a point, and this runs once per
        // layout, not per frame.
        let steps = 64
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let u = 1 - t
            let py = 3 * ch * (1 - round) * u * t * t + ch * t * t * t
            let px = capWidth * u * u * u + 3 * capWidth * (1 - flat) * u * u * t
            if py >= y { return max(px, 0) }
        }
        return 0
    }

    public func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let cw = min(capWidth, r.width / 2)
        let ch = min(capHeight, r.height / 2)
        let hx = cw * flat      // horizontal handle, off the flat edge
        let vy = ch * round     // vertical handle, off the side

        var p = Path()
        p.move(to: CGPoint(x: r.minX + cw, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - cw, y: r.minY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + ch),
                   control1: CGPoint(x: r.maxX - cw + hx, y: r.minY),
                   control2: CGPoint(x: r.maxX, y: r.minY + ch - vy))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - ch))
        p.addCurve(to: CGPoint(x: r.maxX - cw, y: r.maxY),
                   control1: CGPoint(x: r.maxX, y: r.maxY - ch + vy),
                   control2: CGPoint(x: r.maxX - cw + hx, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + cw, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.minX, y: r.maxY - ch),
                   control1: CGPoint(x: r.minX + cw - hx, y: r.maxY),
                   control2: CGPoint(x: r.minX, y: r.maxY - ch + vy))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + ch))
        p.addCurve(to: CGPoint(x: r.minX + cw, y: r.minY),
                   control1: CGPoint(x: r.minX, y: r.minY + ch - vy),
                   control2: CGPoint(x: r.minX + cw - hx, y: r.minY))
        p.closeSubpath()
        return p
    }
}
