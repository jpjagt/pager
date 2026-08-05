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
    /// case (`.resizable(resizingMode: .tile)`, `.interpolation(.none)`) at
    /// low opacity with `.overlay` blending. Generated once, on first access,
    /// and cached for the rest of the process's lifetime.
    ///
    /// Round 1 of the visual gate found the grain invisible even at 10%
    /// overlay opacity: at 1 raw pixel per point it was too fine to survive
    /// downscaling/8-bit flattening. The source noise is now rasterized at
    /// `rawPixelSize` (64×64 — half the tile's point dimensions, so one raw
    /// noise pixel covers 2 device points once tiled) and the resulting
    /// `NSImage` is stamped with the *larger* `tileSize` as its point size,
    /// so it's upscaled on draw; consumers pair this with
    /// `.interpolation(.none)` so that upscale stays blocky instead of
    /// blurring the grain back into invisibility. Contrast is also boosted
    /// before desaturating, since flat mid-grey static reads as nothing at
    /// low opacity — wider black/white swings survive the overlay blend.
    public static let tile: NSImage = generateTile()

    /// Raw noise resolution in pixels. Half of `tileSize` so each texel
    /// covers ~2 device points once the tile is stamped at `tileSize` points
    /// and tiled — see `tile`'s doc comment.
    private static let rawPixelSize = tileSize / 2

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
        // NSImage's "size" is in points, independent of the backing
        // CGImage's pixel dimensions — stamping it as `tileSize` (not
        // `rawSize`) is what makes the coarse raw grain cover ~2pt per texel.
        return NSImage(cgImage: cgImage, size: NSSize(width: tileSize, height: tileSize))
    }
}
