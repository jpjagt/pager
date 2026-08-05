import SwiftUI
import PagerCore

/// An inverted-video LCD status row — `backlight`-colored text on an `ink`
/// ground, the inverse of normal panel content (which is `ink` text on
/// `backlight`). Real backlit LCDs render their status/mode line this way;
/// it's the standard way a one-line device tells "this row is chrome, not
/// your content" without a second color.
///
/// Two styles:
/// - `.plain(String)` — a static informational row.
/// - `.action([Segment])` — a row built from a sequence of words, some of
///   which carry a tap action (`update now`, `hide me`, a detected URL).
///   Copy is never hard-coded here — callers supply `Segment`s, keeping this
///   view a pure renderer.
///
/// When several banners stack (e.g. an offline notice above an update
/// prompt), separate them with `VStack(spacing: 1)` — 1pt reads as a single
/// dark LCD pixel between two lit rows at this scale, rather than a visible
/// gap of case color showing through.
public struct Banner: View {
    /// One word (or run of words) in an `.action` banner. Segments without
    /// an `action` render as plain inverted text; segments with one render
    /// underlined and respond to taps — the LCD-status-line equivalent of a
    /// link.
    public struct Segment: Identifiable {
        public let id = UUID()
        public let text: String
        public let action: (() -> Void)?
        /// Identifies the tappable segment for UI testing. Ignored for
        /// segments with no `action` (nothing interactive to find).
        public let accessibilityIdentifier: String?

        public init(_ text: String, accessibilityIdentifier: String? = nil, action: (() -> Void)? = nil) {
            self.text = text
            self.accessibilityIdentifier = accessibilityIdentifier
            self.action = action
        }
    }

    public enum Style {
        case plain(String)
        case action([Segment])
    }

    private let palette: ScreenPalette
    private let style: Style

    public init(palette: ScreenPalette, style: Style) {
        self.palette = palette
        self.style = style
    }

    public var body: some View {
        HStack(spacing: 4) {
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        .background(ink)
        .accessibilityIdentifier("banner")
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .plain(let text):
            styledText(text)
        case .action(let segments):
            ForEach(segments) { segment in
                if let action = segment.action {
                    Button(action: action) {
                        styledText(segment.text)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(segment.accessibilityIdentifier ?? "banner-action")
                } else {
                    styledText(segment.text)
                }
            }
        }
    }

    private func styledText(_ text: String) -> Text {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(backlight)
    }

    private var backlight: Color { color(palette.backlight) }
    private var ink: Color { color(palette.ink) }

    private func color(_ hex: String) -> Color {
        Color(nsColor: TextUtil.color(fromHex: hex) ?? .gray)
    }
}
