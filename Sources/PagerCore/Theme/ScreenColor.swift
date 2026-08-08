import Foundation

/// The color palette for a lit LCD panel. Every field is an opaque `"#RRGGBB"`
/// hex string — no alpha, no blend mode. Those are rendering decisions and
/// stay in the view layer; a palette only describes color identity.
public struct ScreenPalette {
    /// The lit LCD field.
    public let backlight: String
    /// Text on the LCD — pure black or pure white, whichever the backlight
    /// can carry.
    public let ink: String
    /// Bloom bleeding from the lit panel onto the surrounding bezel.
    public let glow: String
    /// Menu bar text + image thumbnail border, rendered on a LIGHT menu bar.
    public let menuBarInkOnLight: String
    /// Same role, rendered on a DARK menu bar. A single `menuBarInk` value
    /// would vanish on one background or the other.
    public let menuBarInkOnDark: String

    public init(backlight: String, ink: String, glow: String,
                menuBarInkOnLight: String, menuBarInkOnDark: String) {
        self.backlight = backlight
        self.ink = ink
        self.glow = glow
        self.menuBarInkOnLight = menuBarInkOnLight
        self.menuBarInkOnDark = menuBarInkOnDark
    }

    /// Picks the menu bar ink for the background the item is actually sitting
    /// on. The input is the *menu bar's* darkness, not the system's Light/Dark
    /// setting: macOS tints the translucent menu bar from the wallpaper, so a
    /// Light-Mode Mac with a dark picture behind the menu bar gets a dark menu
    /// bar — and the on-light variant would be unreadable there. The caller
    /// (`StatusItemController`) reads that darkness off the status item
    /// button's own effective appearance.
    public func menuBarInk(onDarkMenuBar isDark: Bool) -> String {
        isDark ? menuBarInkOnDark : menuBarInkOnLight
    }
}

/// One of the six backlit-LCD color themes a pager's screen can take.
/// Assigned per-link at creation (see `AppearancePrefs.screenColor`).
public enum ScreenColor: String, Codable, CaseIterable {
    case green, blue, pink, orange, red, indigo

    /// The palette is total — every case resolves to a complete set of hex
    /// values, no optionals.
    public var palette: ScreenPalette {
        switch self {
        case .green:
            return ScreenPalette(backlight: "#85DA5E", ink: "#000000", glow: "#BCEBA6",
                                  menuBarInkOnLight: "#36671E", menuBarInkOnDark: "#C3E8B0")
        case .blue:
            return ScreenPalette(backlight: "#1A63C2", ink: "#FFFFFF", glow: "#81A9DD",
                                  menuBarInkOnLight: "#1E3D67", menuBarInkOnDark: "#B0C8E8")
        case .pink:
            return ScreenPalette(backlight: "#FAA7C8", ink: "#000000", glow: "#FCCFE1",
                                  menuBarInkOnLight: "#671E3B", menuBarInkOnDark: "#E8B0C6")
        case .orange:
            return ScreenPalette(backlight: "#FF9B21", ink: "#000000", glow: "#FFC885",
                                  menuBarInkOnLight: "#673F1E", menuBarInkOnDark: "#E8C9B0")
        case .red:
            return ScreenPalette(backlight: "#B70900", ink: "#FFFFFF", glow: "#D77873",
                                  menuBarInkOnLight: "#67211E", menuBarInkOnDark: "#E8B3B0")
        case .indigo:
            // Reads as purple on screen; the case keeps its persisted rawValue.
            return ScreenPalette(backlight: "#B2A1EE", ink: "#000000", glow: "#D5CBF6",
                                  menuBarInkOnLight: "#221452", menuBarInkOnDark: "#CFC8EA")
        }
    }

    /// First color in `allCases` order not present in `taken`, ignoring
    /// duplicates and ordering within `taken`. Wraps to `.green` once all
    /// six are present. Used to assign a new link a screen color distinct
    /// from its siblings.
    public static func nextUnused(taken: [ScreenColor]) -> ScreenColor {
        let takenSet = Set(taken)
        return allCases.first { !takenSet.contains($0) } ?? .green
    }
}
