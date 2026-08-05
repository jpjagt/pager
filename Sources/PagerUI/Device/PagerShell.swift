import SwiftUI
import PagerCore

/// The molded-plastic case body: a rounded shell filled with a top-lit
/// gradient, a hard bevel pair framing the edge, and a subtle noise grain so
/// it reads as physical material rather than a flat rounded rectangle.
///
/// `PagerShell` draws the case, its bottom key row, and the debossed
/// wordmark — no screen — around whatever `content` (the `LCDPanel`) it's
/// given.
public struct PagerShell<Content: View>: View {
    private let palette: CasePalette
    private let cornerRadius: CGFloat
    private let content: Content
    private let pressedKey: PagerKeyRow.Key?
    private let onClear: () -> Void
    private let onMenu: () -> Void
    private let onClose: () -> Void
    private let onSend: () -> Void

    public init(palette: CasePalette, cornerRadius: CGFloat = 18, pressedKey: PagerKeyRow.Key? = nil,
                onClear: @escaping () -> Void = {}, onMenu: @escaping () -> Void = {},
                onClose: @escaping () -> Void = {}, onSend: @escaping () -> Void = {},
                @ViewBuilder content: () -> Content) {
        self.palette = palette
        self.cornerRadius = cornerRadius
        self.pressedKey = pressedKey
        self.onClear = onClear
        self.onMenu = onMenu
        self.onClose = onClose
        self.onSend = onSend
        self.content = content()
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    public var body: some View {
        ZStack {
            body(shape)
            noiseOverlay
            bevel
            VStack(spacing: 0) {
                content
                    .padding(.horizontal, cornerRadius * 0.55)
                    .padding(.top, cornerRadius * 0.55)
                Spacer(minLength: 8)
                keyRow
                    .padding(.horizontal, cornerRadius * 0.7)
                    .padding(.bottom, cornerRadius * 0.55)
            }
        }
        .accessibilityIdentifier("pager-shell")
    }

    /// The bottom row: the debossed wordmark at the left, the physical keys
    /// at the right. Laid out together (per the brief) since both read off
    /// the same `palette` and sit in the same trough at the bottom of the
    /// case.
    private var keyRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Wordmark(palette: palette)
            Spacer(minLength: 12)
            PagerKeyRow(palette: palette, pressed: pressedKey,
                        onClear: onClear, onMenu: onMenu, onClose: onClose, onSend: onSend)
        }
    }

    /// The case fill: a plain top-to-bottom gradient. A validation spike
    /// (round 1 of this task's visual gate) showed the native
    /// `.shadow(.inner(...))` assist bled well past the edge into a
    /// full-width wash — with `shellBottom` already a dark grey, the two
    /// stacked into a heavy vignette that read as two horizontal stripes
    /// rather than an edge. Dropped entirely; the whole bevel illusion now
    /// comes from the single stroked ring in `bevel`.
    private func body(_ shape: RoundedRectangle) -> some View {
        shape
            .fill(
                LinearGradient(
                    colors: [color(palette.shellTop), color(palette.shellBottom)],
                    startPoint: .top, endPoint: .bottom
                )
            )
    }

    /// The bevel: a single thin (~1.5pt) stroke run around the *whole*
    /// perimeter, colored by an `AngularGradient` centered on the shape.
    /// `edgeHighlight` peaks where the sweep passes the top-left corner,
    /// `edgeShadow` peaks at the bottom-right corner, and the two stops blend
    /// continuously the rest of the way around (`AngularGradient` wraps its
    /// last stop back into its first) — so the line is a light-catch at one
    /// corner fading smoothly into a shadow-pool at the opposite corner,
    /// with no hard seam anywhere. This replaced a pair of `strokeBorder`s
    /// each masked to a top/bottom half with a hard 45%/55% stop: the mask's
    /// discontinuity was exactly the horizontal line cutting across the face
    /// that the visual gate flagged. A single continuous angular sweep can't
    /// produce that seam by construction.
    ///
    /// The stop locations (0.307/0.807, not the "square" 0.375/0.875 that a
    /// naive 45°/135° guess gives) are tuned for this landscape shape: the
    /// bearing (clockwise from north) from the shape's center to the corner
    /// arcs' centers depends on the aspect ratio, and this device is much
    /// wider than it is tall. Re-tune if `cornerRadius` or the shell's aspect
    /// ratio changes materially.
    private var bevel: some View {
        shape
            .strokeBorder(
                AngularGradient(
                    gradient: Gradient(stops: [
                        .init(color: color(palette.edgeShadow), location: 0.307),
                        .init(color: color(palette.edgeHighlight), location: 0.807),
                    ]),
                    center: .center
                ),
                lineWidth: 1.5
            )
    }

    /// Procedural grain, tiled across the whole case at low opacity with
    /// overlay blending — this is what sells "molded plastic" instead of
    /// "flat rounded rectangle." `.interpolation(.none)` keeps the coarse
    /// grain blocky when it's scaled up from `NoiseTexture`'s low-res source
    /// instead of being smoothed back into invisibility. See `NoiseTexture`
    /// for why the tile is cached rather than regenerated per frame.
    private var noiseOverlay: some View {
        Image(nsImage: NoiseTexture.tile)
            .interpolation(.none)
            .resizable(resizingMode: .tile)
            .opacity(0.16)
            .blendMode(.overlay)
            .clipShape(shape)
            .allowsHitTesting(false)
    }

    private func color(_ hex: String) -> Color {
        Color(nsColor: TextUtil.color(fromHex: hex) ?? .gray)
    }
}

/// The `LIMINAL` brand wordmark, **debossed** into the case rather than
/// printed on it: the letterforms are filled in the case's own body color
/// (so they read as the same plastic, not an applied label), with a dark
/// "inner offset" peeking above each glyph and a 1px `brandHighlight` edge
/// peeking *below* — the light-below edge is what sells "stamped into
/// plastic"; the opposite order (light above, dark below) reads as raised
/// lettering instead. All three copies are the same text at a 1pt vertical
/// offset from each other, so the case-colored face on top covers all but a
/// 1px sliver of each of the other two.
struct Wordmark: View {
    let palette: CasePalette

    var body: some View {
        ZStack {
            text.foregroundColor(highlight).offset(y: 1)   // light lip, below
            text.foregroundColor(ink).offset(y: -1)         // dark inner shadow, above
            text.foregroundColor(face)                      // case-colored face, on top
        }
        .accessibilityIdentifier("brand-wordmark")
    }

    private var text: Text {
        Text("LIMINAL")
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .tracking(1.6)
    }

    private var face: Color { color(palette.shellBottom) }
    private var ink: Color { color(palette.brandInk) }
    private var highlight: Color { color(palette.brandHighlight) }

    private func color(_ hex: String) -> Color {
        Color(nsColor: TextUtil.color(fromHex: hex) ?? .gray)
    }
}
