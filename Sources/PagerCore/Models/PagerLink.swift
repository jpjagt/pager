import Foundation

public struct AppearancePrefs: Codable, Equatable {
    /// Max rendered width of the menu bar text in points; truncated beyond.
    public var maxWidth: Double
    public var fontSize: Double
    /// "#RRGGBB"; nil = system default menu bar color.
    public var colorHex: String?
    /// 0–1 alpha applied to the menu bar text.
    public var opacity: Double

    public init(maxWidth: Double = 250, fontSize: Double = 13, colorHex: String? = nil,
                opacity: Double = 1) {
        self.maxWidth = maxWidth
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.opacity = opacity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxWidth = try container.decode(Double.self, forKey: .maxWidth)
        fontSize = try container.decode(Double.self, forKey: .fontSize)
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
        // Absent in prefs saved before the option existed.
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
    }
}

public struct PagerLink: Codable, Equatable, Identifiable {
    public let id: UUID
    /// Canonical 16-char share code (entropy + checksum). Never sent anywhere.
    public let code: String
    /// Local-only label, never synced.
    public var nickname: String
    public var appearance: AppearancePrefs
    public var cachedText: String
    public var cachedWrittenAt: Int64

    public var shareCode: ShareCode { ShareCode(entropy: String(code.prefix(14))) }

    public init(id: UUID = UUID(), code: String, nickname: String,
                appearance: AppearancePrefs = AppearancePrefs(),
                cachedText: String = "", cachedWrittenAt: Int64 = 0) {
        self.id = id
        self.code = code
        self.nickname = nickname
        self.appearance = appearance
        self.cachedText = cachedText
        self.cachedWrittenAt = cachedWrittenAt
    }
}
