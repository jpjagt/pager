import SwiftUI
import PagerCore

/// The device body: the moulded plastic case, the glossy faceplate set into
/// it, the keys, the printed wordmark — everything except the screen, which
/// arrives as `content`.
///
/// Layout is **design-space driven**. Every element is positioned from the
/// traced art in `PagerOutlines` rather than from stacks and paddings, which
/// is what keeps the chrome registered against the silhouette: retracing the
/// SVG moves the parts with it. The one exception is the screen, which fills
/// whatever is left between its traced top and bottom insets — so the screen's
/// content is what drives the device's height.
///
/// Nothing here needs a `GeometryReader`. The device width is fixed, so the
/// design-to-point scale is a constant, and the two things that move with
/// height (screen, keys) are anchored to edges rather than to a measured size.
public struct PagerShell<Content: View>: View {
    private let palette: CasePalette
    private let width: CGFloat
    private let content: Content
    private let pressedKey: PagerKeyRow.Key?
    private let onClear: () -> Void
    private let onMenu: () -> Void
    private let onClose: () -> Void
    private let onSend: () -> Void

    public init(palette: CasePalette, width: CGFloat = 360, pressedKey: PagerKeyRow.Key? = nil,
                onClear: @escaping () -> Void = {}, onMenu: @escaping () -> Void = {},
                onClose: @escaping () -> Void = {}, onSend: @escaping () -> Void = {},
                @ViewBuilder content: () -> Content) {
        self.palette = palette
        self.width = width
        self.pressedKey = pressedKey
        self.onClear = onClear
        self.onMenu = onMenu
        self.onClose = onClose
        self.onSend = onSend
        self.content = content()
    }

    /// Design units → points.
    private var scale: CGFloat { width / PagerOutlines.designSize.width }
    private func s(_ designUnits: CGFloat) -> CGFloat { designUnits * scale }

    public var body: some View {
        ZStack {
            caseBody
            noiseOverlay
            caseBevel
            faceplate

            screen
            topCapChrome
            keys
        }
        .frame(width: width)
        // The floor. Below its natural height the outline would stop shrinking
        // while the contents kept going, so the device is not allowed to get
        // there — a real pager doesn't get shorter for a short message either.
        .frame(minHeight: s(PagerOutlines.designSize.height))
        // Clipped to the case so the screen's backlight glow stops at the
        // plastic instead of hanging in the air, and so the window drops
        // AppKit's shadow off a clean silhouette.
        .clipShape(PagerOutlines.outerCase)
        .accessibilityIdentifier("pager-shell")
    }

    // MARK: - Case

    private var caseBody: some View {
        PagerOutlines.outerCase.fill(
            LinearGradient(colors: [color(palette.shellTop), color(palette.shellBottom)],
                           startPoint: .top, endPoint: .bottom))
    }

    /// A single thin stroke run around the whole perimeter, colored by an
    /// `AngularGradient`: `edgeHighlight` peaks near the top-left, `edgeShadow`
    /// at the bottom-right, and the two blend continuously the rest of the way
    /// around (an angular gradient wraps its last stop back into its first).
    /// One continuous sweep cannot produce the horizontal seam that a pair of
    /// half-masked strokes did.
    private var caseBevel: some View {
        PagerOutlines.outerCase.strokeBorder(
            AngularGradient(
                gradient: Gradient(stops: [
                    .init(color: color(palette.edgeShadow), location: 0.307),
                    .init(color: color(palette.edgeHighlight), location: 0.807),
                ]),
                center: .center),
            lineWidth: 1.5)
    }

    /// Procedural grain — what sells "moulded plastic" rather than "a filled
    /// shape". Only the case gets it: the faceplate is a glossy part, and
    /// leaving grain off it is most of what makes the two read as different
    /// materials.
    private var noiseOverlay: some View {
        Image(nsImage: NoiseTexture.tile)
            .interpolation(.none)
            .resizable(resizingMode: .tile)
            .opacity(0.16)
            .blendMode(.overlay)
            .allowsHitTesting(false)
    }

    // MARK: - Faceplate

    /// The glossy black front panel, recessed into the case. Three effects:
    /// sunk (inner shadow dark at top, lit lip at bottom), edged (a rim
    /// picking up the case light), and glossy (a broad sheen whose lower
    /// boundary is an ellipse, not the panel's own outline — that mismatch is
    /// what reads as a reflection rather than a border).
    private var faceplate: some View {
        ZStack {
            PagerOutlines.faceplate.fill(
                LinearGradient(colors: [color(palette.faceplateTop), color(palette.faceplateBottom)],
                               startPoint: .top, endPoint: .bottom)
                    .shadow(.inner(color: .black.opacity(0.75), radius: 6, y: 4))
                    .shadow(.inner(color: .white.opacity(0.10), radius: 2, y: -1)))

            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.20), location: 0.0),
                    .init(color: .white.opacity(0.05), location: 0.5),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom)
                .mask(Ellipse().scaleEffect(x: 1.3, y: 0.55).offset(y: -s(60)))
                .clipShape(PagerOutlines.faceplate)
                .blendMode(.screen)

            PagerOutlines.faceplate.strokeBorder(color(palette.faceplateEdge).opacity(0.55), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier("faceplate")
    }

    // MARK: - Screen

    /// The screen sits at its traced insets on three sides and absorbs all
    /// remaining height on the fourth. That's the whole growth mechanism from
    /// the content's side: a longer message makes this taller, which makes the
    /// device taller, which the outlines absorb in their walls.
    private var screen: some View {
        content
            .padding(.leading, s(PagerOutlines.lcd.minX))
            .padding(.trailing, s(PagerOutlines.designSize.width - PagerOutlines.lcd.maxX))
            .padding(.top, s(PagerOutlines.lcd.minY))
            .padding(.bottom, s(PagerOutlines.designSize.height - PagerOutlines.lcd.maxY))
    }

    // MARK: - Top cap

    /// The wordmark and the close key both live above both outline apexes, so
    /// they are rigid: they never move or rescale however tall the device
    /// gets. Anchoring them to the top edge is all that's needed.
    private var topCapChrome: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            Wordmark(palette: palette, scale: scale)
                .frame(width: s(PagerOutlines.wordmark.width), height: s(PagerOutlines.wordmark.height))
                .offset(x: s(PagerOutlines.wordmark.minX), y: s(PagerOutlines.wordmark.minY))

            CloseKey(palette: palette, diameter: s(PagerOutlines.closeKeyRadius * 2),
                     pressed: pressedKey == .close, action: onClose)
                .offset(x: s(PagerOutlines.closeKeyCenter.x - PagerOutlines.closeKeyRadius),
                        y: s(PagerOutlines.closeKeyCenter.y - PagerOutlines.closeKeyRadius))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Bottom cap

    /// The keys live below both apexes, so they translate with the bottom cap
    /// and never distort. Anchoring them to the bottom edge reproduces that
    /// translation exactly, with no delta arithmetic here.
    private var keys: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
            PagerKeyRow(palette: palette, scale: scale, pressed: pressedKey,
                        onClear: onClear, onMenu: onMenu, onSend: onSend)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private func color(_ hex: String) -> Color {
        Color(nsColor: TextUtil.color(fromHex: hex) ?? .gray)
    }
}

/// The `LIMINAL` wordmark, **printed** on the faceplate rather than debossed
/// into the case — the reference device prints its brand light on the glossy
/// black panel, and a deboss reads as moulded plastic, which the faceplate
/// isn't. One flat pass of `palette.wordmark`, no offset copies.
struct Wordmark: View {
    let palette: CasePalette
    let scale: CGFloat

    var body: some View {
        Text("LIMINAL")
            .font(.system(size: 10 * scale / 0.742, weight: .medium, design: .rounded))
            .tracking(2.4 * scale / 0.742)
            .foregroundColor(color(palette.wordmark))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityIdentifier("brand-wordmark")
    }

    private func color(_ hex: String) -> Color {
        Color(nsColor: TextUtil.color(fromHex: hex) ?? .gray)
    }
}

/// The close key: a flat red disc in the case's top-left pocket, deliberately
/// plain next to the moulded rocker and send keys. It used to be the third
/// band of the rocker, where it was both the hardest glyph to centre and the
/// narrowest band; out here it has fixed geometry and a fixed position.
struct CloseKey: View {
    let palette: CasePalette
    let diameter: CGFloat
    let pressed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            face
        }
        .buttonStyle(FlatDiscButtonStyle(forcedPressed: pressed))
        .frame(width: diameter, height: diameter)
        .accessibilityIdentifier("key-close")
        .accessibilityLabel("close")
    }

    private var face: some View {
        ZStack {
            Circle().fill(color(palette.closeTop))
            Circle().strokeBorder(color(palette.closeBottom), lineWidth: max(1, diameter * 0.07))
            Image(systemName: "xmark")
                .font(.system(size: diameter * 0.42, weight: .bold))
                .foregroundColor(color(palette.closeGlyph))
        }
    }

    private func color(_ hex: String) -> Color {
        Color(nsColor: TextUtil.color(fromHex: hex) ?? .gray)
    }
}

/// Flat press feedback: a dim and a hair of shrink, no bevel inversion. The
/// moulded keys invert their gradient because they're physical rockers; this
/// one is a printed disc and should not pretend otherwise.
struct FlatDiscButtonStyle: ButtonStyle {
    var forcedPressed: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || forcedPressed
        return configuration.label
            .brightness(pressed ? -0.12 : 0)
            .scaleEffect(pressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}
