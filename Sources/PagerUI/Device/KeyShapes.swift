import SwiftUI
import PagerCore

// MARK: - Rocker geometry

/// Geometry for the two-key rocker (`C` · `···`). The rocker reads as **one
/// moulded leaf** split by a single diagonal seam, not two buttons sitting
/// next to each other.
///
/// Both keys are the *same* traced silhouette (`PagerOutlines.rockerLeaf`)
/// intersected with a wedge, so (a) the two bands union back to exactly the
/// leaf — no lens-shaped gap down the middle, which is what two stock shapes
/// side by side produce — and (b) each band's outer edge is literally a piece
/// of the traced curve rather than a re-derived approximation of it.
enum RockerGeometry {
    /// Fraction of the leaf's width where the `C`|`···` seam sits.
    static let divider: CGFloat = 0.5

    /// How far the seam's bottom endpoint shifts right of its top, as a
    /// fraction of height — what makes the seam an actual diagonal cut,
    /// matching the case's single top-left key light, rather than a vertical
    /// one.
    static let seamSlant: CGFloat = 0.24

    static func seamTop(_ f: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + f * rect.width - seamSlant * rect.height / 2, y: rect.minY)
    }

    static func seamBottom(_ f: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + f * rect.width + seamSlant * rect.height / 2, y: rect.maxY)
    }

    /// Centre x-offset (from the leaf's own centre) of the band spanning
    /// `[f0, f1]` — used to place each key's glyph in the middle of its own
    /// band, since both key shapes are evaluated over the same full-width rect.
    static func bandCenterOffsetX(from f0: CGFloat, to f1: CGFloat, width: CGFloat) -> CGFloat {
        (((f0 + f1) / 2) - 0.5) * width
    }

    /// One band of the rocker: the leaf clipped to the wedge between `f0` and
    /// `f1`. `f0 == 0` / `f1 == 1` mean "no seam that side".
    ///
    /// Clipped through `CGPath` rather than SwiftUI's `Path.intersection`,
    /// which is macOS 14+; this app targets 13.
    static func band(in rect: CGRect, from f0: CGFloat, to f1: CGFloat) -> Path {
        let clipped = PagerOutlines.rockerLeaf.path(in: rect).cgPath
            .intersection(wedge(in: rect, from: f0, to: f1).cgPath)
        return Path(clipped)
    }

    /// The clipping wedge: a quadrilateral bounded by the two seam lines, each
    /// extended past the leaf along its own slant so the cut keeps the seam's
    /// exact angle. `f == 0`/`f == 1` degenerate into a vertical line far
    /// outside the part, i.e. no cut on that side.
    private static func wedge(in rect: CGRect, from f0: CGFloat, to f1: CGFloat) -> Path {
        let outside = rect.width + rect.height

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

/// One of the two moulded rocker keys — `C` (clear) and `···` (menu), left to
/// right. Both derive their region from `RockerGeometry` over the *same* full
/// leaf rect rather than their own geometry, which is what makes the shared
/// edge one identical line instead of two independently-rounded borders.
public struct RockerKey: Shape {
    public enum Position: Sendable { case leading, trailing }
    public let position: Position

    public init(_ position: Position) { self.position = position }

    public func path(in rect: CGRect) -> Path {
        switch position {
        case .leading:
            return RockerGeometry.band(in: rect, from: 0, to: RockerGeometry.divider)
        case .trailing:
            return RockerGeometry.band(in: rect, from: RockerGeometry.divider, to: 1)
        }
    }
}

/// The seam between the two rocker bands, drawn as a thin stroked overlay on
/// top of the key fills so the rocker reads as one moulded part with a groove
/// rather than one undifferentiated blob (two adjoining fills of the same
/// gradient would otherwise blend into a single shape with no visible
/// division at all).
struct RockerSeam: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: RockerGeometry.seamTop(RockerGeometry.divider, in: rect))
        p.addLine(to: RockerGeometry.seamBottom(RockerGeometry.divider, in: rect))
        return p
    }
}

/// The send key's right-pointing arrow — a shaft with a triangular head, not a
/// play triangle: the key sends, it doesn't play. Every corner is eased by a
/// short cubic fillet, because raw points look printed and the key's whole
/// story is moulded plastic.
struct ArrowGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let shaftHalf = rect.height * 0.19
        let headBase = rect.minX + rect.width * 0.52
        let corners = [
            CGPoint(x: rect.maxX, y: rect.midY),               // tip
            CGPoint(x: headBase, y: rect.maxY),                // head, bottom barb
            CGPoint(x: headBase, y: rect.midY + shaftHalf),    // concave notch
            CGPoint(x: rect.minX, y: rect.midY + shaftHalf),   // shaft, bottom-left
            CGPoint(x: rect.minX, y: rect.midY - shaftHalf),   // shaft, top-left
            CGPoint(x: headBase, y: rect.midY - shaftHalf),    // concave notch
            CGPoint(x: headBase, y: rect.minY),                // head, top barb
        ]
        let ease = min(rect.width, rect.height) * 0.12

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

/// Debossed glyph: a dark copy offset half a point down, a light copy on top —
/// the "stamped into the key" look, rather than flat printed text.
struct KeyGlyph: View {
    let text: String
    let color: Color
    var size: CGFloat = 13

    var body: some View {
        ZStack {
            glyph.foregroundColor(.black.opacity(0.35)).offset(y: 0.6)
            glyph.foregroundColor(color)
        }
    }

    private var glyph: Text {
        Text(text).font(.system(size: size, weight: .bold, design: .rounded))
    }
}

/// The send key's arrow, debossed the way `KeyGlyph` debosses text.
struct KeyArrow: View {
    let color: Color
    var width: CGFloat = 15
    var height: CGFloat = 16

    var body: some View {
        ZStack {
            arrow(.black.opacity(0.35)).offset(y: 0.7)
            arrow(color)
        }
        .frame(width: width, height: height)
    }

    private func arrow(_ color: Color) -> some View {
        ArrowGlyph().fill(color)
    }
}

/// The gloss anatomy shared by the moulded keys — recess, gradient body, a top
/// gloss highlight whose lower boundary is an ellipse rather than the button's
/// own outline (so it reads as a reflection, not a border), a bottom bounce
/// light, and a contact shadow. Factored out of `PagerKeyButtonStyle` so
/// `design-preview` can render a forced "pressed" look directly: there's no
/// live user input inside a headless render, so the preview binary needs a way
/// to ask for the pressed appearance without a real `Button` press.
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
            // The recess is a stroke, not a scaled copy of the shape: half the
            // stroke hides under the fill, so what shows is a ring of constant
            // width hugging the outline. Scaling the shape instead produced a
            // ring that was visibly wider along the flatter parts of the curve.
            if showsRecess {
                shape.stroke(Color.black.opacity(0.32), lineWidth: pressed ? 3 : 7)
            }

            // Body — the gradient direction inverts when pressed, so the bevel
            // itself flips rather than just dimming.
            shape.fill(
                LinearGradient(colors: pressed ? [bottom, top] : [top, bottom],
                               startPoint: .top, endPoint: .bottom))

            // A flat dimming wash, pressed only, on top of the already-inverted
            // body so the key reads noticeably darker when sunk rather than
            // merely re-lit from another angle.
            if pressed {
                shape.fill(Color.black.opacity(0.22))
            }

            // Top gloss. Its lower boundary is an ellipse mask offset upward,
            // not the shape's own outline. The ellipse alone clipped the key's
            // upper corners (the lozenge's top-right, the leaf's top-left), so
            // the mask unions in a rectangle pinned to the top edge — full
            // coverage up top, the elliptical boundary below. Pressed pushes
            // the ellipse down and dims it hard — a sunk key catches far less
            // of the case light.
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(pressed ? 0.12 : 0.92), location: 0.0),
                    .init(color: .white.opacity(pressed ? 0.03 : 0.35), location: 0.45),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom)
                .mask(ZStack {
                    Rectangle().scaleEffect(y: 0.4, anchor: .top)
                    Ellipse().scaleEffect(x: 1.2, y: 0.7).offset(y: pressed ? 2 : -7)
                })
                .clipShape(shape)
                .blendMode(.screen)

            // Bottom bounce light — thin, bottom-third only. Pressed loses it
            // almost entirely (no under-lip left to catch light once the key is
            // flush with its well).
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
/// and inverts its bevel.
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

/// The moulded keys: the two-key rocker leaf and the send lozenge, each
/// positioned from its traced design-space rect. Both live below the outline
/// apexes, so `PagerShell` anchors this to the device's bottom edge and they
/// translate rigidly as the device grows.
///
/// The close key is deliberately **not** here — it's a flat disc in the case's
/// top-left pocket (`CloseKey` in `PagerShell`). `pressed` still accepts
/// `.close` so `design-preview` can address every key through one enum.
public struct PagerKeyRow: View {
    public enum Key: Equatable { case clear, menu, close, send }

    private let palette: CasePalette
    private let scale: CGFloat
    private let pressed: Key?
    private let onClear: () -> Void
    private let onMenu: () -> Void
    private let onSend: () -> Void

    public init(palette: CasePalette, scale: CGFloat = 1, pressed: Key? = nil,
                onClear: @escaping () -> Void = {}, onMenu: @escaping () -> Void = {},
                onSend: @escaping () -> Void = {}) {
        self.palette = palette
        self.scale = scale
        self.pressed = pressed
        self.onClear = onClear
        self.onMenu = onMenu
        self.onSend = onSend
    }

    private func s(_ designUnits: CGFloat) -> CGFloat { designUnits * scale }

    /// Distance from the design space's bottom edge up to a traced rect's
    /// bottom — how far above the device's bottom edge the part sits.
    private func bottomMargin(of rect: CGRect) -> CGFloat {
        PagerOutlines.designSize.height - rect.maxY
    }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear

            // Lifted 3pt off its traced position: the leaf as traced sits a
            // hair too deep in the case's bottom edge.
            rocker
                .frame(width: s(rockerBounds.width), height: s(rockerBounds.height))
                .offset(x: s(rockerBounds.minX), y: -s(bottomMargin(of: rockerBounds)) - 3)

            sendKey
                .frame(width: s(sendBounds.width), height: s(sendBounds.height))
                .offset(x: s(sendBounds.minX), y: -s(bottomMargin(of: sendBounds)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .accessibilityIdentifier("pager-key-row")
    }

    private var rockerBounds: CGRect { PagerOutlines.rockerLeaf.designBounds }
    private var sendBounds: CGRect { PagerOutlines.sendLozenge.designBounds }

    private var rocker: some View {
        ZStack {
            // No dark recess around the leaf — it sits in the faceplate's own
            // black region, so an extra halo just read as a smudge. The thin
            // edge stroke is all the separation it needs.
            PagerOutlines.rockerLeaf
                .stroke(keyEdge.opacity(0.9), lineWidth: 1)

            keyButton(.clear, shape: RockerKey(.leading), action: onClear) {
                KeyGlyph(text: "C", color: keyGlyph, size: 13 * scale / 0.742)
                    .offset(x: RockerGeometry.bandCenterOffsetX(
                        from: 0, to: RockerGeometry.divider, width: s(rockerBounds.width)))
            }
            keyButton(.menu, shape: RockerKey(.trailing), action: onMenu) {
                KeyGlyph(text: "···", color: keyGlyph, size: 12 * scale / 0.742)
                    .offset(x: RockerGeometry.bandCenterOffsetX(
                        from: RockerGeometry.divider, to: 1, width: s(rockerBounds.width)))
            }

            // Clipped to the leaf: the seam line runs edge-to-edge of the
            // layout rect, and only the part crossing the moulding is a groove.
            RockerSeam()
                .stroke(keyEdge.opacity(0.85), lineWidth: 1)
                .clipShape(PagerOutlines.rockerLeaf)
                .allowsHitTesting(false)
        }
        .accessibilityIdentifier("rocker-key")
    }

    private var sendKey: some View {
        keyButton(.send, shape: PagerOutlines.sendLozenge, top: sendTop, bottom: sendBottom,
                  showsRecess: true, action: onSend) {
            // Sized against the lozenge's visual body rather than its bounding
            // box — the traced shape is a lopsided teardrop, so its bbox
            // overstates how much room the glyph actually has.
            KeyArrow(color: sendGlyph, width: s(28), height: s(24))
        }
        .accessibilityIdentifier("send-key")
    }

    /// Renders either the live interactive button (default) or, when `pressed`
    /// names this key, a static forced-pressed face with no `Button` at all —
    /// the latter exists only so `design-preview` can screenshot the sunk look.
    @ViewBuilder
    private func keyButton<S: Shape, Content: View>(
        _ id: Key, shape: S, top: Color? = nil, bottom: Color? = nil, showsRecess: Bool = false,
        action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Content
    ) -> some View {
        let topColor = top ?? keyTop
        let bottomColor = bottom ?? keyBottom
        if pressed == id {
            PagerKeyFace(shape: shape, top: topColor, bottom: bottomColor, pressed: true,
                         showsRecess: showsRecess, label: label)
                .accessibilityIdentifier(identifier(for: id))
        } else {
            Button(action: action) { label() }
                .buttonStyle(PagerKeyButtonStyle(shape: shape, top: topColor, bottom: bottomColor,
                                                 showsRecess: showsRecess))
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
    private var keyGlyph: Color { color(palette.keyGlyph) }
    private var sendGlyph: Color { color(palette.sendGlyph) }
    private var sendTop: Color { color(palette.sendTop) }
    private var sendBottom: Color { color(palette.sendBottom) }

    private func color(_ hex: String) -> Color {
        Color(nsColor: TextUtil.color(fromHex: hex) ?? .gray)
    }
}
