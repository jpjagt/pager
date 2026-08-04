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

    // MARK: Popover container (full-width padded box, native-size image)

    /// Padding between the container edge and the image, all sides.
    public static let containerPadding: Double = 3
    /// Height floor for the container (= 120 Retina px).
    public static let containerMinHeight: Double = 60
    /// Stored pixels → display points (images come from Retina screenshots).
    public static let pixelScale: Double = 2

    public struct ContainerLayout: Equatable {
        public let containerSize: CGSize
        /// The displayed image size, centered inside the container.
        public let imageSize: CGSize

        public init(containerSize: CGSize, imageSize: CGSize) {
            self.containerSize = containerSize
            self.imageSize = imageSize
        }
    }

    /// The popover model: a full-width container with dark padding around the
    /// image at its native (pixels ÷ 2) size — scaled down to fit, never up.
    /// Container height hugs the image but stays ≥ `containerMinHeight` and,
    /// like `boxSize`, never gets taller than 9:16 of its width.
    public static func containerLayout(imagePixelSize: CGSize,
                                       containerWidth: Double) -> ContainerLayout {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0, containerWidth > 0 else {
            return ContainerLayout(containerSize: .zero, imageSize: .zero)
        }
        let contentWidth = containerWidth - 2 * containerPadding
        let maxContentHeight = containerWidth / minAspect - 2 * containerPadding
        let natural = CGSize(width: imagePixelSize.width / pixelScale,
                             height: imagePixelSize.height / pixelScale)
        let scale = min(1, contentWidth / natural.width, maxContentHeight / natural.height)
        let image = CGSize(width: natural.width * scale, height: natural.height * scale)
        let height = max(containerMinHeight, image.height + 2 * containerPadding)
        return ContainerLayout(containerSize: CGSize(width: containerWidth, height: height),
                               imageSize: image)
    }
}
