import AppKit
import SwiftUI
import PagerCore

/// The key/unfocused state of one `PagerWindow`, published so the hosted
/// SwiftUI content can react to focus changes (the LCD backlight dims when the
/// window stops being key). A published object rather than a re-created root
/// view, so the change can animate.
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
/// 2. The shadow is AppKit's own (`hasShadow = true`), which on a transparent
///    window is derived from the rendered content's alpha — so it traces the
///    case's actual silhouette, end caps and all. It is *cached*, though:
///    every content-driven resize has to `invalidateShadow()` or the pager
///    keeps the shadow of whatever height it used to be. This replaced a
///    hand-drawn SwiftUI shadow that existed so it could soften on focus
///    loss; the window frame no longer carries transparent slack for a blur
///    to land in, so it is exactly the device the user sees. (The focus cue
///    itself didn't go away — `PagerDeviceView` dims the backlight.)
@MainActor
final class PagerWindow: NSWindow, NSWindowDelegate {
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
    /// Fired on any mouse-down inside the device. The only listener is the
    /// open-fresh edit: a click means the user placed the caret (or grabbed the
    /// case to drag it), so the next keystroke must not wipe the message.
    var onMouseDown: (() -> Void)?

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
        // The device never adapts to Light/Dark: its screen is a lit, light
        // panel in every theme and its ink is the palette's dark `ink`, full
        // stop. The SwiftUI subtree pins `colorScheme` itself
        // (`PagerDeviceView`), but the message field is a real `NSTextField`
        // underneath and takes its system-drawn bits — selection wash, the
        // insertion point, any control it grows — from the *window's*
        // appearance, so that is pinned here too.
        appearance = NSAppearance(named: .aqua)
        hasShadow = true // AppKit's own, off the case silhouette — see the type doc
        level = .floating
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        // Explicitly opt out of AppKit's automatic show/hide animation — left
        // at `.default`, AppKit fades borderless utility-style windows in and
        // out. Appear/disappear must be instantaneous; the *shadow* still
        // animates on focus change, but that is drawn in SwiftUI (see
        // `PagerWindowChrome` below) and is unrelated to this setting.
        animationBehavior = .none
        // Follow the user across Spaces, and stay visible over a full-screen
        // app — an always-on-top note that vanishes on the next Space isn't.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        delegate = self

        let hosting = NSHostingController(rootView: content(focus))
        // Height follows content: SwiftUI republishes its preferred size as
        // text wraps or an image lands, and the window tracks it.
        hosting.sizingOptions = [.preferredContentSize]
        contentViewController = hosting
    }

    /// Without this the text field can never take focus. See the type doc.
    override var canBecomeKey: Bool { true }

    /// Observed, never intercepted: the event is always passed on. Watching it
    /// here rather than in the SwiftUI content because the whole device — case,
    /// keys and screen — counts as "the user clicked", and `isMovableByWindowBackground`
    /// means most of that surface has no control to hang a gesture on.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { onMouseDown?() }
        super.sendEvent(event)
    }

    // MARK: - Geometry

    /// The device as the user sees it. Since the window dropped its shadow
    /// slack this is just the frame — kept as a name of its own because it is
    /// what `PagerLink.windowFrame` persists, and rects saved by older
    /// versions are in these same (visible-device) coordinates, so they
    /// restore unchanged.
    var visibleDeviceFrame: CGRect { frame }

    /// The device's current natural size.
    private var deviceSize: CGSize {
        guard let view = contentViewController?.view else { return .zero }
        view.layoutSubtreeIfNeeded()
        return view.fittingSize
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

        isPlacing = true
        setFrame(visible, display: true)
        invalidateShadow()
        // Anchor to the *intended* top, not the resulting frame: SwiftUI can
        // still be a few points out on its first measurement (before the view
        // has a window backing it), and `reanchor()` pulls it back.
        anchoredTop = visible.maxY
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
        if let screen = Self.screen(for: visible) ?? NSScreen.main {
            // Vertically only: the device's width never changes with content,
            // so a horizontal nudge here could only be fighting a drag the
            // user meant. Growth is downward, and that is what has to be caught.
            visible.origin.y = PagerWindowPlacement.clamp(visible, in: screen.visibleFrame).origin.y
        }
        guard abs(visible.minX - frame.minX) > 0.5 || abs(visible.minY - frame.minY) > 0.5 else { return }
        isPlacing = true
        setFrameOrigin(visible.origin)
        isPlacing = false
        // A clamp moves the top edge; that clamped top is the new anchor, or
        // the next resize would pull the device straight back off-screen.
        anchoredTop = visible.maxY
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

    /// Writes `text` straight into the message field, caret at the end.
    ///
    /// Needed because SwiftUI will not push a *shortened* binding value into a
    /// `TextField` that is currently being edited — verified: the field editor
    /// keeps the string the user typed and the next keystroke re-syncs the
    /// model from it, so a wipe done through the binding silently undoes
    /// itself. Anything that replaces the message mid-edit (the open-fresh
    /// wipe, and the ⌘Z that puts it back) therefore has to come through here.
    func setMessageFieldText(_ text: String) {
        guard let field = Self.firstTextField(in: contentView) else { return }
        let editor: NSText? = (field as? NSTextField)?.currentEditor() ?? field as? NSText
        guard let editor else {
            (field as? NSTextField)?.stringValue = text // not being edited yet
            return
        }
        editor.string = text
        editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
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
        // AppKit caches the shadow it derived from the old alpha mask; without
        // this the device keeps the silhouette of whatever height it was
        // before the message wrapped or an image landed.
        invalidateShadow()
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
