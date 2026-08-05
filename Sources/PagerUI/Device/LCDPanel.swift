import SwiftUI
import PagerCore

/// The recessed, backlit LCD well — the pager's screen. Must read as three
/// separate effects layered together (per the skeuomorphic reference doc):
/// **sunk** (inner shadow + a dark bezel-toned rim, the opposite polarity of
/// `PagerShell`'s raised case body — recessed levels get the inner shadow
/// dark-at-top / lit-lip-at-bottom), **lit** (an outer glow bleeding onto the
/// surrounding case), and **inked** (content always drawn in the palette's
/// `ink`, never `.primary`/`.black`, since a real backlit LCD's ink is a dark
/// tint of the backlight hue, not neutral black).
///
/// `LCDPanel` draws only the well + backlight fill; it does not know about
/// the case's `bezel` color (that lives in `CasePalette` one layer up), so
/// the sunk rim here uses a fixed near-black tone matched to how a bezel
/// reads under glass rather than importing `CasePalette` as a dependency —
/// this view only receives `ScreenPalette`.
public struct LCDPanel<Content: View>: View {
    private let palette: ScreenPalette
    private let content: Content

    /// Matches `PagerShell`'s rim treatment in weight; a recessed well reads
    /// convincingly with a slightly tighter radius than the outer shell.
    private let cornerRadius: CGFloat = 10

    public init(palette: ScreenPalette, @ViewBuilder content: () -> Content) {
        self.palette = palette
        self.content = content()
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    public var body: some View {
        ZStack {
            fill
            content
                .foregroundColor(ink)
                .padding(10)
        }
        .background(
            // The glow lives BEHIND the well and is intentionally larger than
            // it (via .shadow's blur radius), so it bleeds onto the
            // surrounding case rather than staying confined to the panel's
            // own silhouette. Two stacked shadows (tight+bright, wide+soft)
            // read closer to a real backlight bloom than one radius alone —
            // a single shadow either stayed a hairline or, past ~radius 20,
            // went uniformly soft with no "hot" center.
            shape
                .fill(backlight)
                .shadow(color: glow.opacity(0.9), radius: 6)
                .shadow(color: glow.opacity(0.55), radius: 22)
        )
        .overlay(rim)
        .accessibilityIdentifier("lcd-panel")
    }

    /// The lit field plus the sunk inner shadow. Recessed levels (per the
    /// reference doc) get the inner shadow dark-at-top / lit-lip-at-bottom —
    /// the inverse of a raised level like `PagerShell`'s body, which would be
    /// light-at-top / dark-at-bottom.
    private var fill: some View {
        shape
            .fill(
                backlight
                    .shadow(.inner(color: .black.opacity(0.45), radius: 5, y: 3))
                    .shadow(.inner(color: .white.opacity(0.16), radius: 2, y: -1))
            )
    }

    /// The dark bezel-toned stroke ring that frames the sunk well — this,
    /// together with the inner shadow in `fill`, is what sells "recessed"
    /// rather than just "a colored rectangle."
    private var rim: some View {
        shape
            .strokeBorder(Color.black.opacity(0.55), lineWidth: 1.5)
    }

    private var backlight: Color { color(palette.backlight) }
    private var ink: Color { color(palette.ink) }
    private var glow: Color { color(palette.glow) }

    private func color(_ hex: String) -> Color {
        Color(nsColor: TextUtil.color(fromHex: hex) ?? .gray)
    }
}
