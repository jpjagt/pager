import Foundation

public struct AppearancePrefs: Codable, Equatable {
    /// Max rendered width of the menu bar text in points; truncated beyond.
    public var maxWidth: Double
    public var fontSize: Double
    /// 0–1 alpha applied to the menu bar text.
    public var opacity: Double
    /// The lit-LCD screen color theme.
    public var screenColor: ScreenColor
    /// The molded-plastic case color.
    public var caseColor: CaseColor

    public init(maxWidth: Double = 250, fontSize: Double = 13, opacity: Double = 1,
                screenColor: ScreenColor = .green, caseColor: CaseColor = .darkGrey) {
        self.maxWidth = maxWidth
        self.fontSize = fontSize
        self.opacity = opacity
        self.screenColor = screenColor
        self.caseColor = caseColor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxWidth = try container.decode(Double.self, forKey: .maxWidth)
        fontSize = try container.decode(Double.self, forKey: .fontSize)
        // Absent in prefs saved before the option existed.
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        // Absent in prefs saved before the theme reskin (the old free-form
        // color field is ignored, not migrated — an explicit product
        // decision). A decode failure here would wipe the user's links, so
        // these must default rather than throw.
        screenColor = try container.decodeIfPresent(ScreenColor.self, forKey: .screenColor) ?? .green
        caseColor = try container.decodeIfPresent(CaseColor.self, forKey: .caseColor) ?? .darkGrey
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
    /// True when the cached content is an image (bytes live in ImageDiskCache;
    /// cachedText is "" in that case).
    public var cachedIsImage: Bool
    /// Persisted popover window frame, restored on next open. Nil until the
    /// user first moves/resizes it (or for links saved before this existed).
    public var windowFrame: CGRect?

    public var shareCode: ShareCode { ShareCode(entropy: String(code.prefix(14))) }

    enum CodingKeys: String, CodingKey {
        case id, code, nickname, appearance, cachedText, cachedWrittenAt, cachedIsImage, windowFrame
    }

    public init(id: UUID = UUID(), code: String, nickname: String,
                appearance: AppearancePrefs = AppearancePrefs(),
                cachedText: String = "", cachedWrittenAt: Int64 = 0,
                cachedIsImage: Bool = false, windowFrame: CGRect? = nil) {
        self.id = id
        self.code = code
        self.nickname = nickname
        self.appearance = appearance
        self.cachedText = cachedText
        self.cachedWrittenAt = cachedWrittenAt
        self.cachedIsImage = cachedIsImage
        self.windowFrame = windowFrame
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        code = try container.decode(String.self, forKey: .code)
        nickname = try container.decode(String.self, forKey: .nickname)
        appearance = try container.decode(AppearancePrefs.self, forKey: .appearance)
        cachedText = try container.decode(String.self, forKey: .cachedText)
        cachedWrittenAt = try container.decode(Int64.self, forKey: .cachedWrittenAt)
        // Absent in links saved before image support.
        cachedIsImage = try container.decodeIfPresent(Bool.self, forKey: .cachedIsImage) ?? false
        // Absent until the user first moves/resizes the popover, or in links
        // saved before this existed.
        windowFrame = try container.decodeIfPresent(CGRect.self, forKey: .windowFrame)
    }
}
