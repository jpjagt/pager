import Foundation

/// Pure display-box math shared by the popover image view and the menu bar
/// thumbnail: fit within max bounds, but never let the box get narrower than
/// 9:16 — taller images letterbox inside the clamped box.
public enum ImageDisplayMath {
    /// Narrowest allowed box aspect (width / height).
    public static let minAspect: Double = 9.0 / 16.0

    public static func boxSize(imageSize: CGSize, maxWidth: Double, maxHeight: Double) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, maxWidth > 0, maxHeight > 0 else {
            return .zero
        }
        let aspect = max(imageSize.width / imageSize.height, minAspect)
        let height = min(maxHeight, maxWidth / aspect)
        return CGSize(width: height * aspect, height: height)
    }
}
