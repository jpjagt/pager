import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageCodecError: Error, Equatable {
    case notAnImage
    case cannotEncode
}

/// Re-encodes any readable image (PNG/JPEG/HEIC/GIF/TIFF…) to a JPEG small
/// enough to live E2E-encrypted inside the RTDB node. ImageIO only — no AppKit,
/// so this stays headless-testable in PagerCore.
public enum ImageCodec {
    public static let maxEncodedBytes = 600_000
    /// Long-edge caps, tried in order if the encoded size won't come down.
    static let longEdges: [CGFloat] = [1024, 768, 512]
    static let qualities: [CGFloat] = [0.8, 0.6, 0.4, 0.25]

    public static func isDecodableImage(_ data: Data) -> Bool {
        pixelSize(of: data) != nil
    }

    public static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Double,
              let height = props[kCGImagePropertyPixelHeight] as? Double
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Downscale to ≤ 1024 px long edge and JPEG-encode, stepping quality (then
    /// dimensions) down until the result fits maxEncodedBytes.
    public static func process(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { throw ImageCodecError.notAnImage }
        for edge in longEdges {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
                // Bake EXIF rotation into the pixels so receivers need no metadata.
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary) else { throw ImageCodecError.notAnImage }
            for quality in qualities {
                let out = NSMutableData()
                guard let dest = CGImageDestinationCreateWithData(
                    out, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw ImageCodecError.cannotEncode
                }
                CGImageDestinationAddImage(
                    dest, image,
                    [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { throw ImageCodecError.cannotEncode }
                if out.length <= maxEncodedBytes { return out as Data }
            }
        }
        throw ImageCodecError.cannotEncode
    }
}
