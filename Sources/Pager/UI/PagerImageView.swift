import SwiftUI
import PagerCore

/// Clickable image container shared by the draft image and the URL preview:
/// always full width with a rounded 2pt border slightly lighter than the
/// popover background, dark padding around the image, and the image itself at
/// native (Retina) size — scaled down to fit, never up. Very tall images cap
/// the container at 9:16 and center horizontally. Pointer cursor + subtle dim
/// on hover, optional ✕.
struct PagerImageView: View {
    let imageData: Data
    let onTap: () -> Void
    var onClear: (() -> Void)?
    @State private var hovering = false

    /// Popover is 360pt wide with 16pt padding.
    static let width: Double = 328

    var body: some View {
        if let pixelSize = ImageCodec.pixelSize(of: imageData),
           let nsImage = NSImage(data: imageData) {
            let layout = ImageDisplayMath.containerLayout(
                imagePixelSize: pixelSize, containerWidth: Self.width)
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Color.black.opacity(0.25) // dark padding around the image
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: layout.imageSize.width, height: layout.imageSize.height)
                        // Concentric with the container: 6pt outer − 3pt padding.
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    if hovering { Color.black.opacity(0.1) }
                }
                if hovering, let onClear {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white, .black.opacity(0.55))
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }
            }
            .frame(width: layout.containerSize.width, height: layout.containerSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 2))
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }
}
