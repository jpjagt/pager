import Foundation

public struct AppearancePrefs: Codable, Equatable {
    /// Max rendered width of the menu bar text in points; truncated beyond.
    public var maxWidth: Double
    public var fontSize: Double
    /// "#RRGGBB"; nil = system default menu bar color.
    public var colorHex: String?

    public init(maxWidth: Double = 250, fontSize: Double = 13, colorHex: String? = nil) {
        self.maxWidth = maxWidth
        self.fontSize = fontSize
        self.colorHex = colorHex
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
