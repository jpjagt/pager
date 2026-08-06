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
    /// Fires when the menu bar's own appearance flips (see `appearanceObserver`).
    private var appearanceObserver: NSKeyValueObservation?
    /// What was last drawn, so the item can repaint itself in the other ink
    /// without the AppDelegate having to push the content back in.
    private var lastRender: (content: PagerContent, prefs: AppearancePrefs)?

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
        observeMenuBarAppearance()
    }

    /// The ink is resolved for one menu bar background (see `ink`), so nothing
    /// else would repaint it when that background changes — a wallpaper swap,
    /// or a Light/Dark toggle that the menu bar actually follows.
    ///
    /// Observes the *button*, not `NSApp`: the button lives in the menu bar and
    /// takes its appearance from there, which is a different thing from the
    /// app's (see `isMenuBarDark`). Observing `NSApp` instead would both miss
    /// wallpaper-driven flips and fire on system flips the menu bar ignored.
    ///
    /// `effectiveAppearance` is KVO-compliant on `NSStatusBarButton` — measured
    /// on macOS 14.5 by swapping the desktop picture under a live status item
    /// and watching the callback arrive (black wallpaper → `VibrantDark`, white
    /// → `VibrantLight`), with the polled value agreeing each time. Several
    /// callbacks can land in a burst while the tint settles; `rerender` is
    /// cheap and idempotent, so that is left alone rather than debounced.
    private func observeMenuBarAppearance() {
        guard let button = statusItem.button else { return }
        appearanceObserver = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.rerender() }
        }
    }

    func render(content: PagerContent, prefs: AppearancePrefs) {
        lastRender = (content, prefs)
        switch content {
        case .text(let text): renderText(text, prefs: prefs)
        case .image(let data): renderImage(data, prefs: prefs)
        }
    }

    /// Redraws what is already on screen in the current menu bar ink.
    private func rerender() {
        guard let lastRender else { return }
        render(content: lastRender.content, prefs: lastRender.prefs)
    }

    private func renderImage(_ data: Data, prefs: AppearancePrefs) {
        guard let button = statusItem.button,
              let thumbnail = Self.thumbnail(from: data, maxWidth: prefs.maxWidth,
                                             borderColor: ink(prefs)) else {
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
        let base = ink(prefs)
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
    /// one value would vanish on one background or the other — the on-*dark*
    /// variant is the light one. Resolved (not a dynamic color) so the
    /// `opacity` pref can be applied on top and so the image thumbnail's border
    /// can be stroked into an `NSImage`; `appearanceObserver` repaints when the
    /// menu bar flips.
    private func ink(_ prefs: AppearancePrefs) -> NSColor {
        let hex = prefs.screenColor.palette.menuBarInk(onDarkMenuBar: isMenuBarDark)
        return TextUtil.color(fromHex: hex) ?? .labelColor
    }

    /// Whether the menu bar this item sits in is currently a dark surface.
    ///
    /// Read off the status item button, never `NSApp`: the menu bar is
    /// translucent and tints from the wallpaper, so its darkness and the
    /// system's Light/Dark setting are two different things. Measured on
    /// macOS 14.5, holding Light Mode fixed and changing only the wallpaper:
    ///
    ///     wallpaper   NSApp.effectiveAppearance   button.effectiveAppearance
    ///     dark        Aqua                        VibrantDark  → .darkAqua
    ///     white       Aqua                        VibrantLight → .aqua
    ///
    /// Same app appearance, opposite menu bars — `NSApp` cannot distinguish
    /// these, and the on-light ink is unreadable in the first row (that is the
    /// reported bug). The button tracks the real thing. The converse also
    /// holds: with a dark wallpaper, toggling the system to Dark Mode moved
    /// `NSApp` to `DarkAqua` while the button stayed `VibrantDark`, because the
    /// menu bar was already dark and nothing about it actually changed.
    ///
    /// `bestMatch` rather than a name comparison, because that name is
    /// `NSAppearanceNameVibrantDark`/`VibrantLight`, which equals neither
    /// `.aqua` nor `.darkAqua` — a `== .darkAqua` test would silently read
    /// "light" for every menu bar there is.
    private var isMenuBarDark: Bool {
        statusItem.button?.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
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
