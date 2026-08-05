import SwiftUI
import PagerCore

// MARK: - Shared rocker geometry

/// Geometry shared by the three physical rocker keys (`C` · `···` · `✕`).
/// The rocker reads as **one moulded silhouette** split by two diagonal
/// seams, not three independently-rounded buttons: every band computes its
/// edges from these same functions over the *same* full-width rect, so a
/// seam's two endpoints are numerically identical for both of the bands it
/// separates. A validation spike using three stock `Capsule`/`Ellipse`
/// buttons side by side left a lens-shaped gap at every seam — that's the
/// failure mode this file exists to avoid.
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

    /// Barrel bulge of the top/bottom edges, as a fraction of height. The
    /// top bulge is the larger of the two, per the reference doc's "upper
    /// bulge is larger than the lower one."
    static let topBulge: CGFloat = 0.10
    static let bottomBulge: CGFloat = 0.05

    /// How far the rounded end caps (the rocker's true left/right silhouette
    /// edges) bow outward, as a fraction of height.
    static let capBulge: CGFloat = 0.34

    private static func bulge(_ f: CGFloat, amount: CGFloat, height: CGFloat) -> CGFloat {
        amount * height * (1 - pow(2 * f - 1, 2))
    }

    static func topPoint(_ f: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + f * rect.width,
                y: rect.minY - bulge(f, amount: topBulge, height: rect.height))
    }

    static func bottomPoint(_ f: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + f * rect.width,
                y: rect.maxY + bulge(f, amount: bottomBulge, height: rect.height))
    }

    /// The shared seam at fraction `f` — both bands it separates read these
    /// exact two points rather than computing their own edge, which is what
    /// guarantees they line up.
    static func seamTop(_ f: CGFloat, in rect: CGRect) -> CGPoint { topPoint(f, in: rect) }

    static func seamBottom(_ f: CGFloat, in rect: CGRect) -> CGPoint {
        let base = bottomPoint(f, in: rect)
        return CGPoint(x: base.x + seamSlant * rect.height, y: base.y)
    }

    /// Center x-offset (from the full rocker's own center) of the band
    /// spanning `[f0, f1]` — used to place each key's glyph in the middle of
    /// its own band rather than the rocker's overall center, since all three
    /// key shapes are evaluated over the same full-width rect.
    static func bandCenterOffsetX(from f0: CGFloat, to f1: CGFloat, width: CGFloat) -> CGFloat {
        (((f0 + f1) / 2) - 0.5) * width
    }

    /// One band of the rocker silhouette: cubic-bezier top/bottom edges,
    /// plus either a cubic end cap (the rocker's true outer sides) or a
    /// straight-as-cubic seam (an internal divider shared with a
    /// neighboring band — expressed as a cubic with collinear control
    /// points so every edge in this shape, without exception, is a bezier
    /// curve rather than a stock shape).
    static func band(in rect: CGRect, from f0: CGFloat, to f1: CGFloat,
                      outerLeft: Bool, outerRight: Bool) -> Path {
        var p = Path()
        let topLeft = topPoint(f0, in: rect)
        let topRight = topPoint(f1, in: rect)
        let bottomLeft = outerLeft ? bottomPoint(f0, in: rect) : seamBottom(f0, in: rect)
        let bottomRight = outerRight ? bottomPoint(f1, in: rect) : seamBottom(f1, in: rect)

        p.move(to: topLeft)
        p.addCurve(to: topRight,
                   control1: CGPoint(x: topLeft.x + (topRight.x - topLeft.x) * 0.33, y: topLeft.y),
                   control2: CGPoint(x: topLeft.x + (topRight.x - topLeft.x) * 0.66, y: topRight.y))

        if outerRight {
            let cap = capBulge * rect.height
            p.addCurve(to: bottomRight,
                       control1: CGPoint(x: topRight.x + cap, y: topRight.y + (bottomRight.y - topRight.y) * 0.22),
                       control2: CGPoint(x: bottomRight.x + cap, y: bottomRight.y - (bottomRight.y - topRight.y) * 0.22))
        } else {
            addStraightCubic(&p, from: topRight, to: bottomRight)
        }

        p.addCurve(to: bottomLeft,
                   control1: CGPoint(x: bottomRight.x + (bottomLeft.x - bottomRight.x) * 0.33, y: bottomRight.y),
                   control2: CGPoint(x: bottomRight.x + (bottomLeft.x - bottomRight.x) * 0.66, y: bottomLeft.y))

        if outerLeft {
            let cap = capBulge * rect.height
            p.addCurve(to: topLeft,
                       control1: CGPoint(x: bottomLeft.x - cap, y: bottomLeft.y - (bottomLeft.y - topLeft.y) * 0.22),
                       control2: CGPoint(x: topLeft.x - cap, y: topLeft.y + (bottomLeft.y - topLeft.y) * 0.22))
        } else {
            addStraightCubic(&p, from: bottomLeft, to: topLeft)
        }

        p.closeSubpath()
        return p
    }

    /// A straight line expressed as a cubic bezier with collinear control
    /// points (at 1/3 and 2/3 along the segment) rather than `addLine`.
    private static func addStraightCubic(_ p: inout Path, from start: CGPoint, to end: CGPoint) {
        let c1 = CGPoint(x: start.x + (end.x - start.x) / 3, y: start.y + (end.y - start.y) / 3)
        let c2 = CGPoint(x: start.x + (end.x - start.x) * 2 / 3, y: start.y + (end.y - start.y) * 2 / 3)
        p.addCurve(to: end, control1: c1, control2: c2)
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
            return RockerGeometry.band(in: rect, from: 0, to: RockerGeometry.divider1,
                                        outerLeft: true, outerRight: false)
        case .middle:
            return RockerGeometry.band(in: rect, from: RockerGeometry.divider1, to: RockerGeometry.divider2,
                                        outerLeft: false, outerRight: false)
        case .trailing:
            return RockerGeometry.band(in: rect, from: RockerGeometry.divider2, to: 1,
                                        outerLeft: false, outerRight: true)
        }
    }
}

/// The whole rocker's outer silhouette (all three bands, unioned) — used
/// only to draw one shared recessed trough and rim behind the three key
/// buttons. Not itself a key: drawing a *separate* recess per key would
/// scale each one from the rocker's overall center (since every `RockerKey`
/// band is evaluated over the full shared rect) and distort the off-center
/// bands, which is exactly the "three separate parts" look this task is
/// trying to avoid.
struct RockerSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        RockerGeometry.band(in: rect, from: 0, to: 1, outerLeft: true, outerRight: true)
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

/// The send key: a separate green oval set apart to the right of the
/// rocker, built per the reference doc's "oval with three corners" —
/// three corner points with independently-tuned fillet radii (two sharp, one
/// soft), rather than an `Ellipse`, which is precisely what a validation
/// spike found reads as generic.
public struct SendKey: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let b = rect
        let top = CGPoint(x: b.minX + b.width * 0.52, y: b.minY)
        let left = CGPoint(x: b.minX, y: b.minY + b.height * 0.58)
        let bottom = CGPoint(x: b.minX + b.width * 0.44, y: b.maxY)
        let right = CGPoint(x: b.maxX, y: b.minY + b.height * 0.40)

        var p = Path()
        p.move(to: top)
        p.addArc(tangent1End: left, tangent2End: bottom, radius: b.height * 0.42)    // soft
        p.addArc(tangent1End: bottom, tangent2End: right, radius: b.height * 0.20)   // sharp
        p.addArc(tangent1End: right, tangent2End: top, radius: b.height * 0.22)      // sharp
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

    private static let rockerWidth: CGFloat = 118
    private static let rockerHeight: CGFloat = 36

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

            RockerSeams()
                .stroke(keyEdge.opacity(0.85), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .frame(width: Self.rockerWidth, height: Self.rockerHeight)
        .accessibilityIdentifier("rocker-key")
    }

    private var sendKey: some View {
        keyButton(.send, shape: SendKey(), top: sendTop, bottom: sendBottom, action: onSend) {
            Text("send")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.92))
        }
        .frame(width: 54, height: 34)
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
        } else {
            Button(action: action) { label() }
                .buttonStyle(PagerKeyButtonStyle(shape: shape, top: top, bottom: bottom, showsRecess: id == .send))
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
