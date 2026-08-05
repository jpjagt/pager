import AppKit
import PagerCore

/// Owns one NSStatusItem for one link. The pager itself lives in a
/// `PagerWindow` the AppDelegate manages; this is purely the menu bar half —
/// render the shared line, report clicks, accept drops.
@MainActor
final class StatusItemController: NSObject {
    let linkId: UUID
    private let statusItem: NSStatusItem
    /// Fired when the menu bar item is clicked. AppDelegate decides what that
    /// means (open / raise / commit and close) from the window's state.
    var onClick: (() -> Void)?
    private let dropView = StatusItemDropView()
    /// Fired when something is dropped on the menu bar item. AppDelegate wires
    /// this to an immediate edit+commit (no window involved).
    var onDropPayload: ((DropPayload) -> Void)?

    init(linkId: UUID) {
        self.linkId = linkId
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(buttonClicked)
        if let button = statusItem.button {
            dropView.frame = button.bounds
            dropView.autoresizingMask = [.width, .height]
            dropView.onDrop = { [weak self] payload in self?.onDropPayload?(payload) }
            button.addSubview(dropView)
        }
    }

    func render(content: PagerContent, prefs: AppearancePrefs) {
        switch content {
        case .text(let text): renderText(text, prefs: prefs)
        case .image(let data): renderImage(data, prefs: prefs)
        }
    }

    private func renderImage(_ data: Data, prefs: AppearancePrefs) {
        guard let button = statusItem.button,
              let thumbnail = Self.thumbnail(from: data, maxWidth: prefs.maxWidth,
                                             borderColor: Self.ink(prefs)) else {
            renderText("", prefs: prefs) // unreadable cache → placeholder 📟
            return
        }
        button.attributedTitle = NSAttributedString(string: "")
        button.image = thumbnail
        button.imagePosition = .imageOnly
    }

    private func renderText(_ text: String, prefs: AppearancePrefs) {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.imagePosition = .noImage
        let display = text.isEmpty
            ? "📟"
            : text.replacingOccurrences(of: "\n", with: " ")
        let attributed = NSMutableAttributedString(
            string: display,
            attributes: [.font: NSFont.systemFont(ofSize: prefs.fontSize)])
        let base = Self.ink(prefs)
        let color = prefs.opacity < 1 ? base.withAlphaComponent(prefs.opacity) : base
        attributed.addAttribute(
            .foregroundColor, value: color,
            range: NSRange(location: 0, length: attributed.length))
        for match in TextUtil.detectURLs(in: display) {
            attributed.addAttribute(
                .underlineStyle, value: NSUnderlineStyle.single.rawValue,
                range: match.range)
        }
        button.attributedTitle = Self.truncated(attributed, toWidth: prefs.maxWidth)
    }

    /// The menu bar's ink for this link: its screen color, in the variant made
    /// for the menu bar background currently in use. Two variants exist because
    /// one value would vanish on one appearance or the other — the on-*dark*
    /// variant is the light one. Resolved (not a dynamic color) so the
    /// `opacity` pref can be applied on top; `AppDelegate` re-renders every
    /// item when the system appearance flips.
    static func ink(_ prefs: AppearancePrefs) -> NSColor {
        let palette = prefs.screenColor.palette
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return TextUtil.color(fromHex: isDark ? palette.menuBarInkOnDark
                                              : palette.menuBarInkOnLight) ?? .labelColor
    }

    /// Drops tail characters (before an ellipsis) until the string fits.
    static func truncated(_ attributed: NSAttributedString, toWidth maxWidth: Double) -> NSAttributedString {
        guard attributed.size().width > maxWidth, attributed.length > 1 else { return attributed }
        let ellipsis = NSAttributedString(
            string: "…",
            attributes: attributed.attributes(at: 0, effectiveRange: nil))
        var length = attributed.length
        while length > 1 {
            length -= 1
            let candidate = NSMutableAttributedString(
                attributedString: attributed.attributedSubstring(
                    from: NSRange(location: 0, length: length)))
            candidate.append(ellipsis)
            if candidate.size().width <= maxWidth { return candidate }
        }
        return ellipsis
    }

    // Thumbnail geometry: 2pt border in the link's menu bar ink, 1pt gap,
    // then the image (~16pt tall) — total 22pt, the status bar thickness.
    static let thumbBorderWidth: CGFloat = 2
    static let thumbBorderGap: CGFloat = 1
    static let thumbInnerHeight: CGFloat = 16

    /// Composes the bordered, aspect-clamped menu bar thumbnail. `borderColor`
    /// is the same ink the text line takes, so a pager reads as one color
    /// whether it currently holds text or an image.
    static func thumbnail(from data: Data, maxWidth: Double, borderColor: NSColor) -> NSImage? {
        guard let source = NSImage(data: data),
              source.size.width > 0, source.size.height > 0 else { return nil }
        let inset = thumbBorderWidth + thumbBorderGap
        let box = ImageDisplayMath.boxSize(
            imageSize: CGSize(width: source.size.width, height: source.size.height),
            maxWidth: max(Double(maxWidth) - 2 * Double(inset), 8),
            maxHeight: Double(thumbInnerHeight))
        guard box != .zero else { return nil }
        let total = NSSize(width: box.width + 2 * inset, height: box.height + 2 * inset)
        let image = NSImage(size: total, flipped: false) { rect in
            let borderRect = rect.insetBy(dx: thumbBorderWidth / 2, dy: thumbBorderWidth / 2)
            let border = NSBezierPath(roundedRect: borderRect, xRadius: 4, yRadius: 4)
            border.lineWidth = thumbBorderWidth
            borderColor.setStroke()
            border.stroke()
            let boxRect = rect.insetBy(dx: inset, dy: inset)
            let fitted = Self.fitRect(imageSize: source.size, in: boxRect)
            NSBezierPath(roundedRect: fitted, xRadius: 2, yRadius: 2).setClip()
            source.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Aspect-fit rect for an image centered in a box (letterbox bars stay
    /// transparent — the menu bar background shows through).
    static func fitRect(imageSize: NSSize, in box: NSRect) -> NSRect {
        let scale = min(box.width / imageSize.width, box.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    @objc private func buttonClicked() {
        onClick?()
    }

    func removeFromStatusBar() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
