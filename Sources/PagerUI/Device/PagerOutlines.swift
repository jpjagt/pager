import SwiftUI

/// The traced device geometry, in the design space of the source SVG.
///
/// Every number here comes from a Figma trace over the Motorola Memo Classic
/// reference photo, pasted essentially verbatim so the values stay diffable
/// against the original `d` attributes. Nothing is "cleaned up": the wobble
/// along the case's bottom edge and the flourish at the faceplate's top-left
/// are deliberate, and because both live in a rigid cap (see `TracedOutline`)
/// they render identically at every device height.
///
/// One design space for everything is the load-bearing decision. The case,
/// the faceplate, the screen and the keys are all expressed in the same
/// 485×282 box, so they share one scale and one stretch delta — which is what
/// keeps them nested as the device grows, rather than three shapes being
/// fitted to each other at runtime.
public enum PagerOutlines {
    /// The source SVG's viewBox. The traced curves inset it by ~0.5 units (the
    /// stroke width they were drawn with), which is a third of a point at the
    /// rendered 360 width — not worth normalizing away.
    public static let designSize = CGSize(width: 485, height: 282)

    /// Natural (unstretched) device height at a given width. `PagerDeviceView`
    /// floors the device here: a real pager doesn't get shorter for a short
    /// message, and flooring means the outlines only ever stretch, never
    /// compress.
    public static func naturalHeight(forWidth width: CGFloat) -> CGFloat {
        width * designSize.height / designSize.width
    }

    // MARK: - Outlines

    /// The moulded plastic shell.
    public static let outerCase = TracedOutline(designSize: designSize, segments: chain(
        from: CGPoint(x: 469.324, y: 17.8419),
        [
            (CGPoint(x: 461.011, y: 9.52952), CGPoint(x: 435.497, y: 0.5), CGPoint(x: 257.278, y: 0.5)),
            (CGPoint(x: 74.4033, y: 0.5), CGPoint(x: 38.3513, y: 5.53952), CGPoint(x: 18.1225, y: 19.172)),
            (CGPoint(x: 4.65678, y: 28.2467), CGPoint(x: 0.499982, y: 37.4594), CGPoint(x: 0.5, y: 103.959)),
            (CGPoint(x: 0.500033, y: 226.319), CGPoint(x: 32.0496, y: 264.076), CGPoint(x: 97.8403, y: 269.749)),
            (CGPoint(x: 263.176, y: 284.005), CGPoint(x: 242.997, y: 250.237), CGPoint(x: 343.332, y: 277.14)),
            (CGPoint(x: 417.04, y: 296.903), CGPoint(x: 477.736, y: 238.81), CGPoint(x: 481.512, y: 168.135)),
            (CGPoint(x: 485.289, y: 97.4614), CGPoint(x: 485.783, y: 34.3006), CGPoint(x: 469.324, y: 17.8419)),
        ]))

    /// The glossy black front panel the screen is set into — a separate
    /// moulded part sitting in a shallow recess in the case, not a rim drawn
    /// around the LCD. Named for the real thing rather than "bezel", which is
    /// already an overloaded word here.
    public static let faceplate = TracedOutline(designSize: designSize, segments: chain(
        from: CGPoint(x: 437.718, y: 33.8333),
        [
            (CGPoint(x: 428.479, y: 29.4947), CGPoint(x: 388.407, y: 21.1187), CGPoint(x: 260.546, y: 21.1187)),
            (CGPoint(x: 27.9202, y: 26.1529), CGPoint(x: 22.8647, y: 7.32726), CGPoint(x: 28.7436, y: 129.751)),
            (CGPoint(x: 34.4773, y: 249.151), CGPoint(x: 85.5006, y: 249.149), CGPoint(x: 151.2, y: 249.148)),
            (CGPoint(x: 232.158, y: 249.148), CGPoint(x: 267.38, y: 225.049), CGPoint(x: 287.522, y: 210.482)),
            (CGPoint(x: 340.535, y: 187.195), CGPoint(x: 405.954, y: 185.109), CGPoint(x: 418.569, y: 183.057)),
            (CGPoint(x: 440.433, y: 179.502), CGPoint(x: 455.845, y: 187.284), CGPoint(x: 459.621, y: 116.61)),
            (CGPoint(x: 463.397, y: 45.9355), CGPoint(x: 445.346, y: 37.4153), CGPoint(x: 437.718, y: 33.8333)),
        ]))

    // MARK: - Key shapes

    /// The rocker: one moulded leaf split into two keys (`C` and `···`).
    /// Bounds are the curve's tight extent, not the control polygon's.
    public static let rockerLeaf = TracedShape(
        designBounds: CGRect(x: 48.126, y: 194.859, width: 224.952, height: 51.633),
        segments: chain(
            from: CGPoint(x: 151.514, y: 246.461),
            [
                (CGPoint(x: 203.638, y: 245.773), CGPoint(x: 259.462, y: 228.868), CGPoint(x: 272.172, y: 214.898)),
                (CGPoint(x: 273.535, y: 213.4), CGPoint(x: 273.399, y: 211.387), CGPoint(x: 271.509, y: 210.658)),
                (CGPoint(x: 249.45, y: 202.143), CGPoint(x: 89.6419, y: 192.137), CGPoint(x: 53.6829, y: 195.542)),
                (CGPoint(x: 49.096, y: 195.976), CGPoint(x: 47.122, y: 199.845), CGPoint(x: 48.6204, y: 204.202)),
                (CGPoint(x: 55.4074, y: 223.937), CGPoint(x: 75.4737, y: 247.463), CGPoint(x: 151.514, y: 246.461)),
            ]))

    /// The send key. On the reference device this is a black button carrying a
    /// green bar; ours inverts it — the lozenge itself is the green part, with
    /// a white arrow on top.
    public static let sendLozenge = TracedShape(
        designBounds: CGRect(x: 309.201, y: 196.182, width: 127.543, height: 63.608),
        segments: chain(
            from: CGPoint(x: 309.341, y: 236.605),
            [
                (CGPoint(x: 312.842, y: 259.036), CGPoint(x: 359.216, y: 263.162), CGPoint(x: 380.566, y: 257.52)),
                (CGPoint(x: 432.166, y: 243.885), CGPoint(x: 481.579, y: 177.636), CGPoint(x: 366.658, y: 201.207)),
                (CGPoint(x: 318.183, y: 211.149), CGPoint(x: 307.818, y: 226.847), CGPoint(x: 309.341, y: 236.605)),
            ]))

    // MARK: - Placement, in design coordinates

    /// The screen well. Its height is the only one that grows with the device
    /// — everything above it is rigid, everything below it translates.
    public static let lcd = CGRect(x: 56.8764, y: 60.305, width: 372.094, height: 92.5623)
    public static let lcdCornerRadius: CGFloat = 14.5
    /// Breathing room between the screen's rim and its content, in points
    /// (not design units — it's a legibility margin, not part of the art).
    /// Lives here rather than on `LCDPanel`, which is generic and so can't
    /// hold a static stored property.
    public static let lcdContentPadding: CGFloat = 10

    /// Where the wordmark prints, top-centre of the faceplate — the reference
    /// device's MOTOROLA position. Slightly right of the device's true centre,
    /// which is the trace, not a mistake.
    public static let wordmark = CGRect(x: 177.661, y: 31.5053, width: 142.076, height: 16.1713)

    /// The close key, in the pocket between the case's left edge and the
    /// faceplate's top-left sweep. Centre and radius come from a
    /// largest-inscribed-circle search over that pocket: the biggest circle
    /// that clears both outlines there has radius ≈16, so 9 leaves comfortable
    /// slack on every side. Sits well above both apexes, so it is rigid — it
    /// never moves or rescales as the device grows.
    public static let closeKeyCenter = CGPoint(x: 22, y: 38)
    public static let closeKeyRadius: CGFloat = 9

    // MARK: -

    /// Builds a closed segment chain the way an SVG `d` attribute reads: one
    /// start point, then a run of `C` triples. The final curve is expected to
    /// return to the start.
    private static func chain(from start: CGPoint,
                              _ curves: [(CGPoint, CGPoint, CGPoint)]) -> [Cubic] {
        var origin = start
        return curves.map { control1, control2, end in
            defer { origin = end }
            return Cubic(p0: origin, c1: control1, c2: control2, p1: end)
        }
    }
}
