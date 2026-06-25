import AppKit
import PagerCore

/// Owns one NSStatusItem + its popover for one link.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    let linkId: UUID
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    /// A 1pt sliver pinned to the button's right edge (flexible left margin).
    /// The popover anchors to this instead of the button: as the title widens
    /// the button grows leftward, but this view stays put in screen space, so
    /// the popover tracks the right edge and doesn't drift while typing.
    private let anchorView = NSView()
    var makePopoverContent: (() -> NSViewController)?
    /// Fired when the popover actually closes (chevron, Enter, or click-away).
    /// AppDelegate wires this to the current editor's commit().
    var onClose: (() -> Void)?

    init(linkId: UUID) {
        self.linkId = linkId
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = false
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        if let button = statusItem.button {
            anchorView.autoresizingMask = [.minXMargin] // stick to the right edge
            button.addSubview(anchorView)
        }
    }

    func render(text: String, prefs: AppearancePrefs) {
        guard let button = statusItem.button else { return }
        let display = text.isEmpty
            ? "📟"
            : text.replacingOccurrences(of: "\n", with: " ")
        let attributed = NSMutableAttributedString(
            string: display,
            attributes: [.font: NSFont.systemFont(ofSize: prefs.fontSize)])
        let base = prefs.colorHex.flatMap(TextUtil.color(fromHex:)) ?? .labelColor
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

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.contentViewController = makePopoverContent?()
            // Park the anchor at the current right edge; autoresizing keeps it
            // there as the button resizes during editing.
            anchorView.frame = NSRect(x: button.bounds.maxX - 1, y: 0, width: 1, height: button.bounds.height)
            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() { popover.performClose(nil) }

    func popoverDidClose(_ notification: Notification) {
        onClose?()
    }

    func removeFromStatusBar() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
