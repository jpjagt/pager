import Foundation

/// The decrypted value a pager holds: text or an image (already-processed JPEG
/// bytes). Parsed exactly once at the sync boundary; everything downstream
/// switches on this enum instead of probing wire fields.
public enum PagerContent: Equatable {
    case text(String)
    case image(Data)

    /// Wire value for `PagerValue.type`. Text writes omit the field entirely
    /// (absent ⇒ text) so old clients and old rules accept them unchanged.
    public static let imageWireType = "img"

    public var wireType: String? {
        if case .image = self { return Self.imageWireType }
        return nil
    }

    public var isImage: Bool {
        if case .image = self { return true }
        return false
    }

    /// The text, or "" for an image (what a text-only consumer should show).
    public var textValue: String {
        if case .text(let text) = self { return text }
        return ""
    }

    public var imageData: Data? {
        if case .image(let data) = self { return data }
        return nil
    }

    /// Plaintext size for log lines: chars for text, bytes for an image.
    public var sizeForLog: Int {
        switch self {
        case .text(let text): return text.count
        case .image(let data): return data.count
        }
    }
}
