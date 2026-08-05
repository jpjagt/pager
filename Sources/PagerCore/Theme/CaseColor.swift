import Foundation

/// The color palette for a molded plastic pager case. Every field is an
/// opaque `"#RRGGBB"` hex string — see `ScreenPalette` for why alpha/blend
/// decisions stay out of this table.
public struct CasePalette {
    /// Body gradient stops (top-lit to shadowed).
    public let shellTop: String
    public let shellBottom: String
    /// The bevel pair framing the case edge.
    public let edgeHighlight: String
    public let edgeShadow: String
    /// Dark ring hugging the LCD.
    public let bezel: String
    /// The rocker keys.
    public let keyTop: String
    public let keyBottom: String
    public let keyEdge: String
    /// The send key. Values are the same across both cases today — it's a
    /// physical green button, not a case-colored part — but the role stays
    /// per-`CasePalette` so a future case color is free to diverge.
    public let sendTop: String
    public let sendBottom: String
    /// The debossed wordmark.
    public let brandInk: String
    public let brandHighlight: String

    public init(shellTop: String, shellBottom: String, edgeHighlight: String, edgeShadow: String,
                bezel: String, keyTop: String, keyBottom: String, keyEdge: String,
                sendTop: String, sendBottom: String, brandInk: String, brandHighlight: String) {
        self.shellTop = shellTop
        self.shellBottom = shellBottom
        self.edgeHighlight = edgeHighlight
        self.edgeShadow = edgeShadow
        self.bezel = bezel
        self.keyTop = keyTop
        self.keyBottom = keyBottom
        self.keyEdge = keyEdge
        self.sendTop = sendTop
        self.sendBottom = sendBottom
        self.brandInk = brandInk
        self.brandHighlight = brandHighlight
    }
}

/// One of the two molded-plastic case colors a pager can take.
/// `.darkGrey` is the primary case and default (see `AppearancePrefs.caseColor`);
/// `.beige` is secondary.
public enum CaseColor: String, Codable, CaseIterable {
    case darkGrey, beige

    /// The palette is total — every case resolves to a complete set of hex
    /// values, no optionals. Hues below are a first pass; they get tuned
    /// visually starting Task 3.
    public var palette: CasePalette {
        switch self {
        case .darkGrey:
            return CasePalette(
                shellTop: "#6B6E73", shellBottom: "#3A3C40",
                edgeHighlight: "#B7BBC0", edgeShadow: "#1C1D1F",
                bezel: "#0E0F11",
                keyTop: "#7A7D82", keyBottom: "#4A4D52", keyEdge: "#232427",
                sendTop: "#5FBF56", sendBottom: "#2E7D32",
                brandInk: "#2A2C2F", brandHighlight: "#8C8F94"
            )
        case .beige:
            return CasePalette(
                shellTop: "#E8DCC8", shellBottom: "#C9B896",
                edgeHighlight: "#F5EEDD", edgeShadow: "#8A7A5E",
                bezel: "#3A332A",
                keyTop: "#D9CCB2", keyBottom: "#B8A883", keyEdge: "#6E6148",
                sendTop: "#5FBF56", sendBottom: "#2E7D32",
                brandInk: "#5C4F3A", brandHighlight: "#FFF8E8"
            )
        }
    }
}
