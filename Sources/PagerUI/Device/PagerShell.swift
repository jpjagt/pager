import SwiftUI
import PagerCore

/// The molded-plastic case body: a rounded shell filled with a top-lit
/// gradient, a hard bevel pair framing the edge, and a subtle noise grain so
/// it reads as physical material rather than a flat rounded rectangle.
///
/// `PagerShell` draws only the case — no screen, no keys (those arrive in
/// later tasks) — around whatever `content` it's given.
public struct PagerShell<Content: View>: View {
    private let palette: CasePalette
    private let cornerRadius: CGFloat
    private let content: Content

    public init(palette: CasePalette, cornerRadius: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.palette = palette
        self.cornerRadius = cornerRadius
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
            content
                .padding(cornerRadius * 0.55)
        }
        .accessibilityIdentifier("pager-shell")
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
