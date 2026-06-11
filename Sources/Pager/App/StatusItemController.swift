import AppKit
import PagerCore

/// Owns one NSStatusItem + its popover for one link.
@MainActor
final class StatusItemController: NSObject {
    let linkId: UUID
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    var makePopoverContent: (() -> NSViewController)?

    init(linkId: UUID) {
        self.linkId = linkId
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        popover.behavior = .transient
        popover.animates = false
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
    }

    func render(text: String, prefs: AppearancePrefs) {
        guard let button = statusItem.button else { return }
        let display = text.isEmpty
            ? "📟"
            : text.replacingOccurrences(of: "\n", with: " ")
        let attributed = NSMutableAttributedString(
            string: display,
            attributes: [.font: NSFont.systemFont(ofSize: prefs.fontSize)])
        if let hex = prefs.colorHex, let color = TextUtil.color(fromHex: hex) {
            attributed.addAttribute(
                .foregroundColor, value: color,
                range: NSRange(location: 0, length: attributed.length))
        }
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
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() { popover.performClose(nil) }

    func removeFromStatusBar() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
