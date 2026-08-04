import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Deterministic programmatic fixtures — no binary files in the repo, no
/// randomness (identical bytes on every run).
enum TestImageFactory {
    /// Opaque striped PNG of the given pixel size.
    static func png(width: Int, height: Int) -> Data {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in stride(from: 0, to: width, by: 16) {
            let shade = CGFloat(x % 256) / 255
            ctx.setFillColor(CGColor(red: shade, green: 1 - shade, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 16, height: height))
        }
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
