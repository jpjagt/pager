import AppKit
import SwiftUI

/// Reusable single-window host for SwiftUI content (onboarding, settings).
@MainActor
final class WindowHost<Content: View> {
    private var window: NSWindow?
    private let title: String
    private let size: NSSize

    init(title: String, size: NSSize) {
        self.title = title
        self.size = size
    }

    func show(_ content: Content) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = title
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.contentViewController = NSHostingController(rootView: content)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.close() }
}
