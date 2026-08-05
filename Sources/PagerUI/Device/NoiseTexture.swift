import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// A procedurally generated grain tile used to give the molded-plastic case a
/// physical, non-flat surface. Generated once per process and cached — this
/// is composited into every case render, so regenerating it per frame would
/// be a real performance bug.
public enum NoiseTexture {
    public static let tileSize = 128

    /// A 128×128 desaturated noise tile, meant to be tiled across the case
    /// (`.resizable(resizingMode: .tile)`) at low opacity with `.overlay`
    /// blending. Generated once, on first access, and cached for the rest of
    /// the process's lifetime.
    public static let tile: NSImage = generateTile()

    private static func generateTile() -> NSImage {
        let size = tileSize
        let cropRect = CGRect(x: 0, y: 0, width: size, height: size)
        let fallback = NSImage(size: NSSize(width: size, height: size))

        let context = CIContext()
        let random = CIFilter.randomGenerator()
        guard let randomImage = random.outputImage else { return fallback }

        // Desaturate — raw CIRandomGenerator output is full-color static;
        // the case grain reads as physical texture only once it's greyscale.
        let desaturated = randomImage.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0,
        ])

        let cropped = desaturated.cropped(to: cropRect)
        guard let cgImage = context.createCGImage(cropped, from: cropRect) else { return fallback }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}
