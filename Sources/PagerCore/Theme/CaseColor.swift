import Foundation

/// The color palette for a molded plastic pager case. Every field is an
/// opaque `"#RRGGBB"` hex string — see `ScreenPalette` for why alpha/blend
/// decisions stay out of this table.
///
/// Every colored part of the device reads from here, including the ones that
/// are physically "not case-colored" (the green send key, the red close key).
/// Those stay per-`CasePalette` rather than being hard-coded in the views so a
/// future case is free to diverge, and so no color in the device is
/// unreachable from the theme.
public struct CasePalette {
    /// Body gradient stops (top-lit to shadowed).
    public let shellTop: String
    public let shellBottom: String
    /// The bevel pair framing the case edge.
    public let edgeHighlight: String
    public let edgeShadow: String
    /// The glossy front panel the screen is set into — a separate molded part
    /// recessed into the case, not a rim drawn around the LCD.
    public let faceplateTop: String
    public let faceplateBottom: String
    public let faceplateEdge: String
    /// The rocker keys.
    public let keyTop: String
    public let keyBottom: String
    public let keyEdge: String
    /// The rocker glyphs (`C`, `···`). Must contrast with `keyTop`, which is
    /// why it can't be a fixed white: on the pale beige keys white glyphs wash
    /// out completely.
    public let keyGlyph: String
    /// The send key.
    public let sendTop: String
    public let sendBottom: String
    public let sendGlyph: String
    /// The close key — a physical red part sitting in the case's top-left
    /// pocket, away from the rocker.
    public let closeTop: String
    public let closeBottom: String
    public let closeGlyph: String
    /// The wordmark, printed light on the faceplate the way the reference
    /// device prints its brand — not debossed into the plastic.
    public let wordmark: String

    public init(shellTop: String, shellBottom: String, edgeHighlight: String, edgeShadow: String,
                faceplateTop: String, faceplateBottom: String, faceplateEdge: String,
                keyTop: String, keyBottom: String, keyEdge: String, keyGlyph: String,
                sendTop: String, sendBottom: String, sendGlyph: String,
                closeTop: String, closeBottom: String, closeGlyph: String, wordmark: String) {
        self.shellTop = shellTop
        self.shellBottom = shellBottom
        self.edgeHighlight = edgeHighlight
        self.edgeShadow = edgeShadow
        self.faceplateTop = faceplateTop
        self.faceplateBottom = faceplateBottom
        self.faceplateEdge = faceplateEdge
        self.keyTop = keyTop
        self.keyBottom = keyBottom
        self.keyEdge = keyEdge
        self.keyGlyph = keyGlyph
        self.sendTop = sendTop
        self.sendBottom = sendBottom
        self.sendGlyph = sendGlyph
        self.closeTop = closeTop
        self.closeBottom = closeBottom
        self.closeGlyph = closeGlyph
        self.wordmark = wordmark
    }
}

/// One of the two molded-plastic case colors a pager can take.
/// `.darkGrey` is the primary case and default (see `AppearancePrefs.caseColor`);
/// `.beige` is secondary.
public enum CaseColor: String, Codable, CaseIterable {
    case darkGrey, beige

    /// The palette is total — every case resolves to a complete set of hex
    /// values, no optionals.
    public var palette: CasePalette {
        switch self {
        case .darkGrey:
            return CasePalette(
                shellTop: "#6B6E73", shellBottom: "#3A3C40",
                edgeHighlight: "#B7BBC0", edgeShadow: "#1C1D1F",
                faceplateTop: "#2A2C30", faceplateBottom: "#0B0C0E", faceplateEdge: "#494D53",
                keyTop: "#7A7D82", keyBottom: "#4A4D52", keyEdge: "#232427", keyGlyph: "#F2F4F6",
                sendTop: "#5FBF56", sendBottom: "#2E7D32", sendGlyph: "#FFFFFF",
                closeTop: "#E5544D", closeBottom: "#A31D18", closeGlyph: "#FFFFFF",
                wordmark: "#C7CBD1"
            )
        case .beige:
            return CasePalette(
                shellTop: "#E8DCC8", shellBottom: "#C9B896",
                edgeHighlight: "#F5EEDD", edgeShadow: "#8A7A5E",
                faceplateTop: "#33302B", faceplateBottom: "#0E0D0B", faceplateEdge: "#5A544A",
                keyTop: "#D9CCB2", keyBottom: "#B8A883", keyEdge: "#6E6148", keyGlyph: "#4A3F2D",
                sendTop: "#5FBF56", sendBottom: "#2E7D32", sendGlyph: "#FFFFFF",
                closeTop: "#E5544D", closeBottom: "#A31D18", closeGlyph: "#FFFFFF",
                wordmark: "#D8CFBE"
            )
        }
    }
}
