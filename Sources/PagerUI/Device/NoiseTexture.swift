import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// A procedurally generated grain tile used to give the molded-plastic case a
/// physical, non-flat surface. Generated once per process and cached — this
/// is composited into every case render, so regenerating it per frame would
/// be a real performance bug.
public enum NoiseTexture {
    public static let tileSize = 128

    /// A 128×128-*point* desaturated noise tile, meant to be tiled across the
    /// case (`.resizable(resizingMode: .tile)`) at low opacity with `.overlay`
    /// blending. Generated once, on first access, and cached for the rest of
    /// the process's lifetime.
    ///
    /// Grain is rasterized 1 texel per point: real molded plastic has a fine
    /// matte grain you sense rather than resolve. An earlier round rendered it
    /// at half resolution and upscaled with `.interpolation(.none)`, which read
    /// as blocky TV static instead of a surface — visibility comes from
    /// *contrast* (boosted below before desaturating), not from bigger texels.
    public static let tile: NSImage = generateTile()

    /// Raw noise resolution in pixels — 1:1 with `tileSize`, so one texel
    /// covers one device point. See `tile`'s doc comment.
    private static let rawPixelSize = tileSize

    private static func generateTile() -> NSImage {
        let rawSize = rawPixelSize
        let cropRect = CGRect(x: 0, y: 0, width: rawSize, height: rawSize)
        let fallback = NSImage(size: NSSize(width: tileSize, height: tileSize))

        let context = CIContext()
        let random = CIFilter.randomGenerator()
        guard let randomImage = random.outputImage else { return fallback }

        // Boost contrast, then desaturate — raw CIRandomGenerator output is
        // full-color static; the case grain reads as physical texture only
        // once it's greyscale, and only if its value swing is wide enough to
        // survive being blended in at low opacity.
        let adjusted = randomImage.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0,
            kCIInputContrastKey: 4.0,
        ])

        let cropped = adjusted.cropped(to: cropRect)
        guard let cgImage = context.createCGImage(cropped, from: cropRect) else { return fallback }
        return NSImage(cgImage: cgImage, size: NSSize(width: tileSize, height: tileSize))
    }
}
