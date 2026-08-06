import SwiftUI
import PagerCore

// MARK: - Smooth outlines

/// A closed cubic-bezier outline through four extreme knots — top, right,
/// bottom, left — whose tangent is **axis-aligned at every knot**:
/// horizontal at top and bottom, vertical at left and right.
///
/// That constraint is the whole point. A cusp appears wherever a knot's
/// incoming and outgoing tangents aren't collinear, which is exactly what
/// the previous hand-placed control points produced where the rocker's end
/// caps met its top and bottom edges. Here each knot's two handles are
/// forced onto the same axis pointing opposite ways, so the outline is G1
/// everywhere by construction — there is no way to tune the parameters into
/// a sharp vertex.
///
/// `flat` and `round` are handle lengths as a fraction of each quadrant's
/// x- and y-span. Long horizontal handles (`flat` ≫ 0.55) flatten the top
/// and bottom into a moulded barrel with tightly-turned ends; the circular
/// value is ≈0.55 for both.
struct SmoothOutline {
    var top: CGPoint
    var right: CGPoint
    var bottom: CGPoint
    var left: CGPoint
    var flat: CGFloat
    var round: CGFloat

    var path: Path {
        var p = Path()
        p.move(to: top)
        p.addCurve(to: right,
                   control1: CGPoint(x: top.x + (right.x - top.x) * flat, y: top.y),
                   control2: CGPoint(x: right.x, y: right.y - (right.y - top.y) * round))
        p.addCurve(to: bottom,
                   control1: CGPoint(x: right.x, y: right.y + (bottom.y - right.y) * round),
                   control2: CGPoint(x: bottom.x + (right.x - bottom.x) * flat, y: bottom.y))
        p.addCurve(to: left,
                   control1: CGPoint(x: bottom.x - (bottom.x - left.x) * flat, y: bottom.y),
                   control2: CGPoint(x: left.x, y: left.y + (bottom.y - left.y) * round))
        p.addCurve(to: top,
                   control1: CGPoint(x: left.x, y: left.y - (left.y - top.y) * round),
                   control2: CGPoint(x: top.x - (top.x - left.x) * flat, y: top.y))
        p.closeSubpath()
        return p
    }
}

// MARK: - Shared rocker geometry

/// Geometry shared by the three physical rocker keys (`C` · `···` · `✕`).
/// The rocker reads as **one moulded silhouette** split by two diagonal
/// seams, not three independently-rounded buttons.
///
/// Each band is the *same* silhouette curve intersected with a wedge between
/// two seam lines, so (a) the three bands union back to exactly the
/// silhouette — no lens-shaped gaps, which is what three stock
/// `Capsule`/`Ellipse` buttons side by side produced — and (b) each band's
/// outer edge is literally a piece of the smooth silhouette rather than a
/// re-derived approximation of it, so no band can introduce a corner the
/// whole part doesn't have.
enum RockerGeometry {
    /// Fraction of width where the `C`|`···` seam sits.
    static let divider1: CGFloat = 0.40
    /// Fraction of width where the `···`|`✕` seam sits. The ✕ band is
    /// deliberately the narrowest of the three, so ✕ reads smaller than its
    /// neighbors without needing separate geometry.
    static let divider2: CGFloat = 0.76

    /// How far a seam's bottom endpoint shifts right of its top endpoint,
    /// as a fraction of height. This is what makes each seam an actual
    /// diagonal cut (matching the case's single top-left key light) rather
    /// than a vertical one.
    static let seamSlant: CGFloat = 0.24

    /// Handle lengths for the silhouette. `flat` is high so the top and
    /// bottom run nearly straight across the middle before turning into the
    /// end caps — a long moulded rocker, not a stadium and not an ellipse.
    private static let flat: CGFloat = 1.00
    private static let round: CGFloat = 0.34

    /// The rocker's whole outer silhouette. Slightly asymmetric — the top
    /// knot sits left of center and the two side knots sit either side of
    /// the waist — so it reads as a moulded part lit from the top left
    /// rather than a symmetric primitive.
    static func silhouette(in rect: CGRect) -> Path {
        SmoothOutline(
            top: CGPoint(x: rect.minX + rect.width * 0.46, y: rect.minY),
            right: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.46),
            bottom: CGPoint(x: rect.minX + rect.width * 0.54, y: rect.maxY),
            left: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.54),
            flat: flat, round: round
        ).path
    }

    /// A seam's two endpoints, extended well past the silhouette on both
    /// ends — they only ever matter where they cross the part.
    static func seamTop(_ f: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + f * rect.width - seamSlant * rect.height / 2, y: rect.minY)
    }

    static func seamBottom(_ f: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + f * rect.width + seamSlant * rect.height / 2, y: rect.maxY)
    }

    /// Center x-offset (from the full rocker's own center) of the band
    /// spanning `[f0, f1]` — used to place each key's glyph in the middle of
    /// its own band rather than the rocker's overall center, since all three
    /// key shapes are evaluated over the same full-width rect.
    static func bandCenterOffsetX(from f0: CGFloat, to f1: CGFloat, width: CGFloat) -> CGFloat {
        (((f0 + f1) / 2) - 0.5) * width
    }

    /// One band of the rocker: the silhouette clipped to the wedge between
    /// the seams at `f0` and `f1`. `f0 == 0` / `f1 == 1` mean "no seam that
    /// side" — the wedge simply runs off past the end cap.
    ///
    /// Clipped through `CGPath` rather than SwiftUI's `Path.intersection`,
    /// which is macOS 14+; this app targets 13.
    static func band(in rect: CGRect, from f0: CGFloat, to f1: CGFloat) -> Path {
        let clipped = silhouette(in: rect).cgPath
            .intersection(wedge(in: rect, from: f0, to: f1).cgPath)
        return Path(clipped)
    }

    /// The clipping wedge: a quadrilateral bounded by the two seam lines,
    /// each extended past the silhouette along its own slant so the cut
    /// keeps the seam's exact angle. `f == 0`/`f == 1` degenerate into a
    /// vertical line far outside the part, i.e. no cut on that side.
    private static func wedge(in rect: CGRect, from f0: CGFloat, to f1: CGFloat) -> Path {
        let outside = rect.width + rect.height

        /// The seam at `f`, extended one full height beyond each end.
        func seam(_ f: CGFloat) -> (top: CGPoint, bottom: CGPoint) {
            if f <= 0 { return (CGPoint(x: rect.minX - outside, y: rect.minY - outside),
                                CGPoint(x: rect.minX - outside, y: rect.maxY + outside)) }
            if f >= 1 { return (CGPoint(x: rect.maxX + outside, y: rect.minY - outside),
                                CGPoint(x: rect.maxX + outside, y: rect.maxY + outside)) }
            let t = seamTop(f, in: rect), b = seamBottom(f, in: rect)
            let dx = b.x - t.x, dy = b.y - t.y
            return (CGPoint(x: t.x - dx, y: t.y - dy), CGPoint(x: b.x + dx, y: b.y + dy))
        }

        let start = seam(f0), end = seam(f1)
        var p = Path()
        p.move(to: start.top)
        p.addLine(to: end.top)
        p.addLine(to: end.bottom)
        p.addLine(to: start.bottom)
        p.closeSubpath()
        return p
    }
}

/// One of the three moulded rocker keys — `C` (clear), `···` (menu), `✕`
/// (close), left to right. All three derive their region from
/// `RockerGeometry` over the *same* full rocker rect rather than their own
/// independent geometry, which is what makes adjacent seams identical lines
/// instead of two independently-rounded borders.
public struct RockerKey: Shape {
    public enum Position: Sendable { case leading, middle, trailing }
    public let position: Position

    public init(_ position: Position) { self.position = position }

    public func path(in rect: CGRect) -> Path {
        switch position {
        case .leading:
            return RockerGeometry.band(in: rect, from: 0, to: RockerGeometry.divider1)
        case .middle:
            return RockerGeometry.band(in: rect, from: RockerGeometry.divider1, to: RockerGeometry.divider2)
        case .trailing:
            return RockerGeometry.band(in: rect, from: RockerGeometry.divider2, to: 1)
        }
    }
}

/// The whole rocker's outer silhouette — the curve every band is cut from,
/// drawn directly to give the three keys one shared recessed trough and rim. Not itself a key: drawing a *separate* recess per key would
/// scale each one from the rocker's overall center (since every `RockerKey`
/// band is evaluated over the full shared rect) and distort the off-center
/// bands, which is exactly the "three separate parts" look this task is
/// trying to avoid.
struct RockerSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        RockerGeometry.silhouette(in: rect)
    }
}

/// The two seams between rocker bands, drawn as a thin stroked overlay on
/// top of the three key fills so the rocker reads as one moulded part with
/// grooves rather than one undifferentiated blob (three adjoining fills of
/// the same gradient would otherwise blend into a single shape with no
/// visible division at all).
struct RockerSeams: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for f in [RockerGeometry.divider1, RockerGeometry.divider2] {
            p.move(to: RockerGeometry.seamTop(f, in: rect))
            p.addLine(to: RockerGeometry.seamBottom(f, in: rect))
        }
        return p
    }
}

/// The send key: a separate green key set apart to the right of the rocker,
/// and the largest key on the device.
///
/// A tangent-arc construction (the previous "oval with three corners")
/// pinched into visible points wherever two arcs of very different radii
/// met. This is the same G1 four-knot outline as the rocker with fuller
/// handles — a squared-off, slightly lopsided moulded blob. Handles past the
/// circular ≈0.55, plus knots offset off both axes, are what keep it from
/// reading as an `Ellipse`.
public struct SendKey: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        SmoothOutline(
            top: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY),
            right: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.40),
            bottom: CGPoint(x: rect.minX + rect.width * 0.58, y: rect.maxY),
            left: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.60),
            flat: 0.60, round: 0.58
        ).path
    }
}

/// The send key's right-pointing arrow, in place of a text label — the
/// Memo Classic's own send glyph. A triangle whose corners are eased by
/// short cubic fillets: a raw triangle's three points look printed, and the
/// key's whole story is moulded plastic.
struct ArrowGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let tip = CGPoint(x: rect.maxX, y: rect.midY)
        let topLeft = CGPoint(x: rect.minX, y: rect.minY)
        let bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)
        let corners = [tip, bottomLeft, topLeft]
        let ease = min(rect.width, rect.height) * 0.22

        /// Walks the triangle corner to corner, stopping `ease` short of
        /// each one and rounding through it with a cubic whose handles sit
        /// on the two incident edges.
        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        func towards(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
            let d = max(hypot(to.x - from.x, to.y - from.y), 0.0001)
            return lerp(from, to, min(ease / d, 0.5))
        }

        var p = Path()
        for i in corners.indices {
            let corner = corners[i]
            let previous = corners[(i + corners.count - 1) % corners.count]
            let next = corners[(i + 1) % corners.count]
            let entry = towards(corner, previous)
            let exit = towards(corner, next)
            if i == 0 { p.move(to: entry) } else { p.addLine(to: entry) }
            p.addCurve(to: exit, control1: corner, control2: corner)
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - Gloss anatomy

/// Debossed glyph: a dark copy offset half a point down, a light copy on
/// top — the "stamped into the key" look the reference calls for, rather
/// than flat printed text.
struct KeyGlyph: View {
    let text: String
    var size: CGFloat = 13

    var body: some View {
        ZStack {
            glyph.foregroundColor(.black.opacity(0.55)).offset(y: 0.6)
            glyph.foregroundColor(.white.opacity(0.88))
        }
    }

    private var glyph: Text {
        Text(text).font(.system(size: size, weight: .bold, design: .rounded))
    }
}

/// The send key's arrow, debossed the same way `KeyGlyph` debosses text: a
/// dark copy half a point down, a light copy on top.
struct KeyArrow: View {
    var width: CGFloat = 15
    var height: CGFloat = 16

    var body: some View {
        ZStack {
            arrow(.black.opacity(0.5)).offset(y: 0.7)
            arrow(.white.opacity(0.92))
        }
        .frame(width: width, height: height)
    }

    private func arrow(_ color: Color) -> some View {
        ArrowGlyph().fill(color)
    }
}

/// The gloss anatomy shared by every key — recess, gradient body, a top
/// gloss highlight whose lower boundary is an ellipse rather than the
/// button's own outline (so it reads as a reflection, not a border), a
/// bottom bounce light, and a contact shadow — factored out of
/// `PagerKeyButtonStyle` so `design-preview` can render a forced "pressed"
/// look directly: there's no live user input inside `ImageRenderer`, so the
/// preview binary needs a way to ask for the pressed appearance without a
/// real `Button` press.
public struct PagerKeyFace<S: Shape, Label: View>: View {
    let shape: S
    let top: Color
    let bottom: Color
    let pressed: Bool
    var showsRecess: Bool = true
    let label: () -> Label

    public init(shape: S, top: Color, bottom: Color, pressed: Bool,
                showsRecess: Bool = true, @ViewBuilder label: @escaping () -> Label) {
        self.shape = shape
        self.top = top
        self.bottom = bottom
        self.pressed = pressed
        self.showsRecess = showsRecess
        self.label = label
    }

    public var body: some View {
        ZStack {
            if showsRecess {
                shape.fill(Color.black.opacity(0.32)).scaleEffect(pressed ? 1.05 : 1.14)
            }

            // Body — the gradient direction inverts when pressed, so the
            // bevel itself flips rather than just dimming.
            shape.fill(
                LinearGradient(colors: pressed ? [bottom, top] : [top, bottom],
                                startPoint: .top, endPoint: .bottom)
            )

            // A flat dimming wash, pressed only — on top of the (already
            // inverted) body gradient so the whole key reads noticeably
            // darker/flatter when sunk, not just re-lit from a different
            // angle.
            if pressed {
                shape.fill(Color.black.opacity(0.22))
            }

            // Top gloss. Critically, its lower boundary is an ellipse mask
            // offset upward, not the shape's own outline. Pressed pushes the
            // ellipse further down and dims it hard — a sunk key catches far
            // less of the case light.
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(pressed ? 0.12 : 0.92), location: 0.0),
                    .init(color: .white.opacity(pressed ? 0.03 : 0.35), location: 0.45),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .mask(
                Ellipse()
                    .scaleEffect(x: 1.2, y: 0.7)
                    .offset(y: pressed ? 2 : -7)
            )
            .clipShape(shape)
            .blendMode(.screen)

            // Bottom bounce light — thin, bottom-third only. Pressed loses
            // it almost entirely (there's no under-lip left to catch light
            // once the key is flush with its well).
            shape
                .stroke(Color.white.opacity(pressed ? 0.05 : 0.28), lineWidth: 0.75)
                .mask(LinearGradient(colors: [.clear, .clear, .white], startPoint: .top, endPoint: .bottom))

            label()
        }
        .contentShape(shape)
        .compositingGroup()
        .shadow(color: .black.opacity(pressed ? 0.15 : 0.55), radius: pressed ? 1 : 3, y: pressed ? 0.5 : 2)
        .offset(y: pressed ? 1 : 0)
        .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

/// `ButtonStyle` wrapper around `PagerKeyFace` for live interaction — reads
/// `configuration.isPressed` and forwards it, so a real press sinks the key
/// and inverts its bevel. Static keys (no pressed feedback at all) feel
/// dead, per the brief.
public struct PagerKeyButtonStyle<S: Shape>: ButtonStyle {
    private let shape: S
    private let top: Color
    private let bottom: Color
    private let showsRecess: Bool

    public init(shape: S, top: Color, bottom: Color, showsRecess: Bool = true) {
        self.shape = shape
        self.top = top
        self.bottom = bottom
        self.showsRecess = showsRecess
    }

    public func makeBody(configuration: Configuration) -> some View {
        PagerKeyFace(shape: shape, top: top, bottom: bottom, pressed: configuration.isPressed,
                     showsRecess: showsRecess) {
            configuration.label
        }
    }
}

// MARK: - The key row

/// The physical key row: the three-key rocker (one moulded part, `C` |
/// `···` | `✕`) plus the send key, a separate green oval set apart to its
/// right. `pressed` lets a caller (`design-preview`, for its pressed-state
/// render) force one key's visual into its sunk/inverted look without a
/// live `Button` press.
public struct PagerKeyRow: View {
    public enum Key: Equatable { case clear, menu, close, send }

    // The rocker is the smaller unit of the two: three keys sharing one
    // moulded part, next to a single send key that is deliberately the
    // biggest thing in the row.
    private static let rockerWidth: CGFloat = 104
    private static let rockerHeight: CGFloat = 30
    private static let sendWidth: CGFloat = 48
    private static let sendHeight: CGFloat = 40

    private let palette: CasePalette
    private let pressed: Key?
    private let onClear: () -> Void
    private let onMenu: () -> Void
    private let onClose: () -> Void
    private let onSend: () -> Void

    public init(palette: CasePalette, pressed: Key? = nil,
                onClear: @escaping () -> Void = {}, onMenu: @escaping () -> Void = {},
                onClose: @escaping () -> Void = {}, onSend: @escaping () -> Void = {}) {
        self.palette = palette
        self.pressed = pressed
        self.onClear = onClear
        self.onMenu = onMenu
        self.onClose = onClose
        self.onSend = onSend
    }

    public var body: some View {
        HStack(spacing: 12) {
            rocker
            sendKey
        }
        .accessibilityIdentifier("pager-key-row")
    }

    private var rocker: some View {
        ZStack {
            RockerSilhouette()
                .fill(Color.black.opacity(0.30))
                .scaleEffect(1.08)
                // Pure decoration (the recess the rocker sits in). Left
                // hit-testable it would swallow drags on the case in the seams
                // and the halo around the keys, like `RockerSeams` would.
                .allowsHitTesting(false)
            RockerSilhouette()
                .stroke(keyEdge.opacity(0.9), lineWidth: 1)

            keyButton(.clear, shape: RockerKey(.leading), top: keyTop, bottom: keyBottom, action: onClear) {
                KeyGlyph(text: "C")
                    .offset(x: RockerGeometry.bandCenterOffsetX(from: 0, to: RockerGeometry.divider1, width: Self.rockerWidth))
            }
            keyButton(.menu, shape: RockerKey(.middle), top: keyTop, bottom: keyBottom, action: onMenu) {
                KeyGlyph(text: "···", size: 12)
                    .offset(x: RockerGeometry.bandCenterOffsetX(from: RockerGeometry.divider1, to: RockerGeometry.divider2, width: Self.rockerWidth))
            }
            keyButton(.close, shape: RockerKey(.trailing), top: closeTop, bottom: closeBottom, action: onClose) {
                KeyGlyph(text: "✕", size: 10)
                    .offset(x: RockerGeometry.bandCenterOffsetX(from: RockerGeometry.divider2, to: 1, width: Self.rockerWidth))
            }

            // Clipped to the silhouette: the seam lines run edge-to-edge of
            // the layout rect, and only the part crossing the moulding is a
            // groove.
            RockerSeams()
                .stroke(keyEdge.opacity(0.85), lineWidth: 1)
                .clipShape(RockerSilhouette())
                .allowsHitTesting(false)
        }
        .frame(width: Self.rockerWidth, height: Self.rockerHeight)
        .accessibilityIdentifier("rocker-key")
    }

    private var sendKey: some View {
        keyButton(.send, shape: SendKey(), top: sendTop, bottom: sendBottom, action: onSend) {
            KeyArrow()
        }
        .frame(width: Self.sendWidth, height: Self.sendHeight)
        .accessibilityIdentifier("send-key")
    }

    /// Renders either the live interactive button (default) or, when
    /// `pressed` names this key, a static forced-pressed face with no
    /// `Button` at all — the latter exists only so `design-preview` can
    /// screenshot the sunk look, since `ImageRenderer` never dispatches a
    /// real press.
    @ViewBuilder
    private func keyButton<S: Shape, Content: View>(
        _ id: Key, shape: S, top: Color, bottom: Color,
        action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Content
    ) -> some View {
        if pressed == id {
            PagerKeyFace(shape: shape, top: top, bottom: bottom, pressed: true,
                         showsRecess: id == .send, label: label)
                .accessibilityIdentifier(identifier(for: id))
        } else {
            Button(action: action) { label() }
                .buttonStyle(PagerKeyButtonStyle(shape: shape, top: top, bottom: bottom, showsRecess: id == .send))
                .accessibilityIdentifier(identifier(for: id))
        }
    }

    private func identifier(for key: Key) -> String {
        switch key {
        case .clear: return "key-clear"
        case .menu: return "key-menu"
        case .close: return "key-close"
        case .send: return "key-send"
        }
    }

    private var keyTop: Color { color(palette.keyTop) }
    private var keyBottom: Color { color(palette.keyBottom) }
    private var keyEdge: Color { color(palette.keyEdge) }
    private var sendTop: Color { color(palette.sendTop) }
    private var sendBottom: Color { color(palette.sendBottom) }

    // The ✕ key is a physical red part, like the send key's green — not a
    // case-themed color, and `CasePalette` has no field for it (it only
    // carries the shared `keyTop`/`keyBottom`/`keyEdge` for the rocker as a
    // whole plus `sendTop`/`sendBottom` for the send key).
    private var closeTop: Color { color("#E5544D") }
    private var closeBottom: Color { color("#A31D18") }

    private func color(_ hex: String) -> Color {
        Color(nsColor: TextUtil.color(fromHex: hex) ?? .gray)
    }
}
