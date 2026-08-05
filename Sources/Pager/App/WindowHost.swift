import AppKit
import SwiftUI

/// Reusable single-window host for SwiftUI content (onboarding, settings).
@MainActor
final class WindowHost<Content: View> {
    private var window: NSWindow?
    private let title: String
    private let size: NSSize
    private let autoSize: Bool

    /// `autoSize` lets the window track the SwiftUI content's ideal height
    /// (set a fixed width on the content; height stays intrinsic).
    init(title: String, size: NSSize, autoSize: Bool = false) {
        self.title = title
        self.size = size
        self.autoSize = autoSize
    }

    func show(_ content: Content) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = title
            window.isReleasedWhenClosed = false
            // Follow the user across Spaces. Without this the window stays on
            // the Space it was first opened on, so re-showing it while the user
            // is elsewhere (or in a full-screen app) appears to do nothing.
            window.collectionBehavior = [.moveToActiveSpace]
            window.center()
            self.window = window
        }
        let hosting = NSHostingController(rootView: content)
        if autoSize { hosting.sizingOptions = [.preferredContentSize] }
        window?.contentViewController = hosting
        // Activate first so the window is ordered into an already-frontmost app;
        // orderFrontRegardless covers the case where activation was denied.
        NSApp.activateForWindow()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func close() { window?.close() }
}
