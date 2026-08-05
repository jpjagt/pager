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

    public init(palette: CasePalette, cornerRadius: CGFloat = 26, @ViewBuilder content: () -> Content) {
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
                .padding(cornerRadius * 0.7)
        }
        .accessibilityIdentifier("pager-shell")
    }

    /// The case fill: a top-to-bottom gradient plus a native inner shadow for
    /// a touch of depth. A validation spike showed the inner shadow alone
    /// reads as almost nothing — it's kept here as a subtle assist, with the
    /// real bevel illusion coming from the explicit strokes in `bevel`.
    private func body(_ shape: RoundedRectangle) -> some View {
        shape
            .fill(
                LinearGradient(
                    colors: [color(palette.shellTop), color(palette.shellBottom)],
                    startPoint: .top, endPoint: .bottom
                )
                .shadow(.inner(color: .black.opacity(0.3), radius: 3, x: 0, y: 2))
                .shadow(.inner(color: .white.opacity(0.25), radius: 1, x: 0, y: -1))
            )
    }

    /// The hard bevel: `edgeHighlight` stroked along the top inner edge,
    /// `edgeShadow` along the bottom, each hard-masked to its half so the
    /// transition reads as a distinct light-catch / shadow-pool rather than a
    /// soft gradient smear.
    private var bevel: some View {
        ZStack {
            shape
                .strokeBorder(color(palette.edgeHighlight), lineWidth: 5)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: 0.45),
                            .init(color: .clear, location: 0.55),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            shape
                .strokeBorder(color(palette.edgeShadow), lineWidth: 5)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.45),
                            .init(color: .white, location: 0.55),
                            .init(color: .white, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        }
    }

    /// Procedural grain, tiled across the whole case at low opacity with
    /// overlay blending — this is what sells "molded plastic" instead of
    /// "flat rounded rectangle." See `NoiseTexture` for why it's cached
    /// rather than regenerated per frame.
    private var noiseOverlay: some View {
        Image(nsImage: NoiseTexture.tile)
            .resizable(resizingMode: .tile)
            .opacity(0.10)
            .blendMode(.overlay)
            .clipShape(shape)
            .allowsHitTesting(false)
    }

    private func color(_ hex: String) -> Color {
        Color(nsColor: TextUtil.color(fromHex: hex) ?? .gray)
    }
}
