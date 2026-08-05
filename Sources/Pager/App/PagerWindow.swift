import AppKit
import SwiftUI
import PagerCore

/// The key/unfocused state of one `PagerWindow`, published so the hosted
/// SwiftUI content can animate on focus changes. A published object (rather
/// than re-creating the root view) is what lets the shadow *animate* instead
/// of snapping.
@MainActor
final class PagerWindowFocus: ObservableObject {
    @Published var isFocused = false
}

/// A borderless, always-on-top window holding one pager device. Replaces the
/// old `NSPopover`: it does not auto-dismiss, it can be dragged anywhere, and
/// several may be open at once (one per link, mutually independent).
///
/// Two things about this window are load-bearing and easy to get wrong:
///
/// 1. `canBecomeKey` **must** be overridden — borderless windows refuse key
///    status by default, and a window that can't be key can never give the
///    text field focus.
/// 2. `hasShadow = false`, because AppKit's window shadow can't animate and
///    this one has to soften when focus is lost. The shadow is drawn in
///    SwiftUI instead, which means the window is deliberately *larger* than
///    the visible device by `shadowMargin` on every side. Everything
///    positional therefore goes through `visibleDeviceFrame` /
///    `windowFrame(forVisibleDevice:)` — using the raw window frame for
///    placement or persistence puts the pager visibly off its mark.
@MainActor
final class PagerWindow: NSWindow, NSWindowDelegate {
    /// Transparent slack on every side of the device, holding the SwiftUI
    /// shadow (and the LCD's outer glow, which also bleeds past the case).
    static let shadowMargin: CGFloat = 34

    /// Debounce before a drag is written to `UserDefaults` — `windowDidMove`
    /// fires continuously while dragging and the frame is persisted on every
    /// link, so this must not run per frame.
    private static let persistDelay: TimeInterval = 0.4

    let linkId: UUID
    let focus = PagerWindowFocus()

    /// Fired (debounced) after a drag, with the **visible device** rect.
    var onFrameChanged: ((CGRect) -> Void)?
    /// Fired when the window actually closes, whatever closed it.
    var onClosed: (() -> Void)?

    private var persistWork: DispatchWorkItem?
    /// The dragged-to rect waiting to be written, cleared by whichever of the
    /// debounce timer and `windowWillClose` gets there first — see `flushFrame`.
    private var pendingFrame: CGRect?
    /// True while `show()` positions the window, so our own `setFrame` doesn't
    /// look like a user drag and persist a placement-derived frame.
    private var isPlacing = false
    /// The top edge the user put the pager at. Content growth must not move
    /// it: AppKit resizes a content-sized window around its *bottom* edge, so
    /// a wrapping message would otherwise creep upward line by line.
    private var anchoredTop: CGFloat?

    /// `content` receives the window's focus object so the view it builds can
    /// react to key state; the window can't be handed a finished view because
    /// the view needs something the window owns.
    init<Content: View>(linkId: UUID, @ViewBuilder content: (PagerWindowFocus) -> Content) {
        self.linkId = linkId
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // drawn in SwiftUI — see the type doc
        level = .floating
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        // Follow the user across Spaces, and stay visible over a full-screen
        // app — an always-on-top note that vanishes on the next Space isn't.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        delegate = self

        let hosting = NSHostingController(
            rootView: PagerWindowChrome(focus: focus, margin: Self.shadowMargin) { content(focus) })
        // Height follows content: SwiftUI republishes its preferred size as
        // text wraps or an image lands, and the window tracks it.
        hosting.sizingOptions = [.preferredContentSize]
        contentViewController = hosting
    }

    /// Without this the text field can never take focus. See the type doc.
    override var canBecomeKey: Bool { true }

    // MARK: - Geometry

    /// The device as the user sees it — the window frame minus the shadow
    /// slack. This, never `frame`, is what placement and persistence use.
    var visibleDeviceFrame: CGRect {
        frame.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin)
    }

    static func windowFrame(forVisibleDevice rect: CGRect) -> CGRect {
        rect.insetBy(dx: -shadowMargin, dy: -shadowMargin)
    }

    /// The device's current natural size (the hosting view's fitting size,
    /// less the shadow slack it is padded by).
    private var deviceSize: CGSize {
        guard let view = contentViewController?.view else { return .zero }
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        return CGSize(width: max(fitting.width - 2 * Self.shadowMargin, 0),
                      height: max(fitting.height - 2 * Self.shadowMargin, 0))
    }

    // MARK: - Presentation

    /// Places, shows and focuses the window. `persistedVisibleFrame` is the
    /// link's remembered position (visible-device coordinates); when it is nil
    /// — or points at a screen that is no longer attached — `PagerWindowPlacement`
    /// picks a top-right spot that avoids the pagers already on screen.
    func show(persistedVisibleFrame: CGRect?, avoiding occupied: [CGRect]) {
        let size = deviceSize
        let visible: CGRect
        if let persisted = persistedVisibleFrame, let screen = Self.screen(for: persisted) {
            // Keep the top-left corner the user dragged it to; the height is
            // whatever the current content needs — then clamp, because that
            // height is not the one the pager was parked with (an image may
            // have landed since) and the bottom of the device carries the keys.
            let wanted = CGRect(x: persisted.minX, y: persisted.maxY - size.height,
                                width: size.width, height: size.height)
            visible = PagerWindowPlacement.clamp(wanted, in: screen.visibleFrame)
        } else {
            let screen = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
            visible = PagerWindowPlacement.frame(size: size, in: screen, avoiding: occupied)
        }

        let target = Self.windowFrame(forVisibleDevice: visible)
        isPlacing = true
        setFrame(target, display: true)
        // Anchor to the *intended* top, not the resulting frame: SwiftUI can
        // still be a few points out on its first measurement (before the view
        // has a window backing it), and `reanchor()` pulls it back.
        anchoredTop = target.maxY
        isPlacing = false

        NSApp.activateForWindow()
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        focusTextField()
        reanchor()
        DispatchQueue.main.async { [weak self] in self?.reanchor() }
    }

    /// Restores the anchored top edge after a content-driven resize, and keeps
    /// the grown device on screen: a pager parked low that receives an image
    /// grows ~270 pt downward, which would push its key row past the bottom of
    /// the screen, unreachable and undraggable.
    private func reanchor() {
        guard let top = anchoredTop else { return }
        var visible = CGRect(x: frame.minX, y: top - frame.height,
                             width: frame.width, height: frame.height)
            .insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin)
        if let screen = Self.screen(for: visible) ?? NSScreen.main {
            // Vertically only: the device's width never changes with content,
            // so a horizontal nudge here could only be fighting a drag the
            // user meant. Growth is downward, and that is what has to be caught.
            visible.origin.y = PagerWindowPlacement.clamp(visible, in: screen.visibleFrame).origin.y
        }
        let target = Self.windowFrame(forVisibleDevice: visible)
        guard abs(target.minX - frame.minX) > 0.5 || abs(target.minY - frame.minY) > 0.5 else { return }
        isPlacing = true
        setFrameOrigin(target.origin)
        isPlacing = false
        // A clamp moves the top edge; that clamped top is the new anchor, or
        // the next resize would pull the device straight back off-screen.
        anchoredTop = target.maxY
    }

    /// The attached display a remembered device rect belongs to: the one it
    /// overlaps most. Nil when it overlaps none — an unplugged external
    /// display — in which case the pager is placed afresh rather than restored
    /// into nowhere. Overlap is only how the *screen* is chosen; the rect
    /// itself is then clamped to fit inside it.
    private static func screen(for rect: CGRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let overlap = screen.visibleFrame.intersection(rect)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best
    }

    /// Puts the caret in the message field on open, so the pager can be typed
    /// into the moment it appears.
    ///
    /// SwiftUI's `@FocusState` lives inside the view that owns the field, and
    /// `PagerDeviceView` is a dumb props-in view in `PagerUI` with no focus
    /// input — so focus is taken from the AppKit side instead: on macOS a
    /// SwiftUI `TextField` is backed by a real `NSTextField` in the hosting
    /// view's subtree, and making it first responder is exactly what
    /// `@FocusState` would have done.
    private func focusTextField() {
        guard let field = Self.firstTextField(in: contentView) else { return }
        makeFirstResponder(field)
        // Becoming first responder selects the field's whole contents, which
        // paints a selection wash across the LCD and makes the existing
        // message look like it's about to be typed over. Collapse it to a
        // caret at the end.
        let editor: NSText? = (field as? NSTextField)?.currentEditor() ?? field as? NSText
        if let editor {
            editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        }
    }

    private static func firstTextField(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        for subview in view.subviews {
            if subview is NSTextField || subview is NSTextView { return subview }
            if let found = firstTextField(in: subview) { return found }
        }
        return nil
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { focus.isFocused = true }

    func windowDidResignKey(_ notification: Notification) { focus.isFocused = false }

    /// The window is content-sized, so this fires whenever the message wraps
    /// to another line or an image lands. Growing downward from a fixed top is
    /// what a user expects; AppKit's own behavior (fixed bottom) makes the
    /// device crawl up the screen as you type.
    func windowDidResize(_ notification: Notification) {
        reanchor()
    }

    /// Fires throughout a drag; the write is debounced to the end of it.
    func windowDidMove(_ notification: Notification) {
        guard !isPlacing else { return }
        anchoredTop = frame.maxY
        pendingFrame = visibleDeviceFrame
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushFrame() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.persistDelay, execute: work)
    }

    /// Writes the pending drag — at most once. The debounce timer and
    /// `windowWillClose` both land here, and whoever arrives first clears
    /// `pendingFrame`, so the other is a no-op: a drag finished 50 ms before
    /// Return is still saved, and a timer firing afterwards can't re-write a
    /// stale rect.
    private func flushFrame() {
        persistWork?.cancel()
        persistWork = nil
        guard let rect = pendingFrame else { return }
        pendingFrame = nil
        onFrameChanged?(rect)
    }

    func windowWillClose(_ notification: Notification) {
        flushFrame()
        onClosed?()
    }
}

/// Draws the window's shadow — AppKit's own can't animate, and this one has to
/// soften when the window stops being key. The device is padded by `margin` on
/// every side to give the blur somewhere to land inside the (transparent)
/// window.
private struct PagerWindowChrome<Content: View>: View {
    @ObservedObject var focus: PagerWindowFocus
    let margin: CGFloat
    let content: Content

    init(focus: PagerWindowFocus, margin: CGFloat, @ViewBuilder content: () -> Content) {
        self.focus = focus
        self.margin = margin
        self.content = content()
    }

    var body: some View {
        content
            .shadow(color: .black.opacity(focus.isFocused ? 0.40 : 0.15),
                    radius: focus.isFocused ? 22 : 9,
                    y: focus.isFocused ? 10 : 4)
            .padding(margin)
            .animation(.easeOut(duration: 0.2), value: focus.isFocused)
    }
}
