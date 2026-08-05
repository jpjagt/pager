import Foundation

/// The color palette for a lit LCD panel. Every field is an opaque `"#RRGGBB"`
/// hex string — no alpha, no blend mode. Those are rendering decisions and
/// stay in the view layer; a palette only describes color identity.
public struct ScreenPalette {
    /// The lit LCD field.
    public let backlight: String
    /// Text on the LCD. Tinted toward the screen's hue and dark — a real
    /// backlit LCD's ink is never pure black.
    public let ink: String
    /// Bloom bleeding from the lit panel onto the surrounding bezel.
    public let glow: String
    /// Menu bar text + image thumbnail border, rendered on a LIGHT menu bar.
    public let menuBarInkOnLight: String
    /// Same role, rendered on a DARK menu bar. A single `menuBarInk` value
    /// would vanish on one appearance or the other, since the menu bar
    /// background differs by system appearance.
    public let menuBarInkOnDark: String

    public init(backlight: String, ink: String, glow: String,
                menuBarInkOnLight: String, menuBarInkOnDark: String) {
        self.backlight = backlight
        self.ink = ink
        self.glow = glow
        self.menuBarInkOnLight = menuBarInkOnLight
        self.menuBarInkOnDark = menuBarInkOnDark
    }
}

/// One of the seven backlit-LCD color themes a pager's screen can take.
/// Assigned per-link at creation (see `AppearancePrefs.screenColor`).
public enum ScreenColor: String, Codable, CaseIterable {
    case green, blue, pink, orange, yellow, red, indigo

    /// The palette is total — every case resolves to a complete set of hex
    /// values, no optionals.
    public var palette: ScreenPalette {
        switch self {
        case .green:
            return ScreenPalette(backlight: "#80CF59", ink: "#1D3710", glow: "#AFE495",
                                  menuBarInkOnLight: "#36671E", menuBarInkOnDark: "#C3E8B0")
        case .blue:
            return ScreenPalette(backlight: "#598CCF", ink: "#102137", glow: "#95B7E4",
                                  menuBarInkOnLight: "#1E3D67", menuBarInkOnDark: "#B0C8E8")
        case .pink:
            return ScreenPalette(backlight: "#CF5988", ink: "#371020", glow: "#E495B5",
                                  menuBarInkOnLight: "#671E3B", menuBarInkOnDark: "#E8B0C6")
        case .orange:
            return ScreenPalette(backlight: "#CF8E59", ink: "#372210", glow: "#E4B995",
                                  menuBarInkOnLight: "#673F1E", menuBarInkOnDark: "#E8C9B0")
        case .yellow:
            return ScreenPalette(backlight: "#CFBB59", ink: "#373110", glow: "#E4D795",
                                  menuBarInkOnLight: "#675B1E", menuBarInkOnDark: "#E8DFB0")
        case .red:
            return ScreenPalette(backlight: "#CF5F59", ink: "#371210", glow: "#E49995",
                                  menuBarInkOnLight: "#67211E", menuBarInkOnDark: "#E8B3B0")
        case .indigo:
            // Blue-violet hues carry little luminance (the blue channel weighs
            // least in perceived brightness), so indigo needs a lighter
            // backlight / darker ink than the shared defaults to keep ink
            // legible against it.
            return ScreenPalette(backlight: "#9A8BD0", ink: "#0D0821", glow: "#BFB5E3",
                                  menuBarInkOnLight: "#221452", menuBarInkOnDark: "#CFC8EA")
        }
    }

    /// First color in `allCases` order not present in `taken`, ignoring
    /// duplicates and ordering within `taken`. Wraps to `.green` once all
    /// seven are present. Used to assign a new link a screen color distinct
    /// from its siblings.
    public static func nextUnused(taken: [ScreenColor]) -> ScreenColor {
        let takenSet = Set(taken)
        return allCases.first { !takenSet.contains($0) } ?? .green
    }
}
