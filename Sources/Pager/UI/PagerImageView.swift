import SwiftUI
import PagerCore

/// Clickable image box shared by the draft image and the URL preview: aspect
/// clamped to ≥ 9:16 (taller images letterbox on bars slightly darker than the
/// popover background), pointer cursor + subtle dim on hover, optional ✕.
struct PagerImageView: View {
    let imageData: Data
    let onTap: () -> Void
    var onClear: (() -> Void)?
    @State private var hovering = false

    /// Popover is 360pt wide with 16pt padding.
    static let maxWidth: Double = 328
    static let maxHeight: Double = 240

    var body: some View {
        if let nsImage = NSImage(data: imageData) {
            let box = ImageDisplayMath.boxSize(
                imageSize: CGSize(width: nsImage.size.width, height: nsImage.size.height),
                maxWidth: Self.maxWidth, maxHeight: Self.maxHeight)
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Color.primary.opacity(0.06) // letterbox bars
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
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
            .frame(width: box.width, height: box.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }
}
