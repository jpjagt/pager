import AppKit

extension NSApplication {
    /// Bring this (accessory) app forward before showing a window.
    ///
    /// `activate(ignoringOtherApps:)` is deprecated on macOS 14, which replaced
    /// it with cooperative activation — the old call is honoured inconsistently
    /// there, which is why an accessory app's windows can open behind whatever
    /// the user was using. Sparkle makes the same split internally
    /// (`SPUStandardUserDriver._activateApplication`).
    func activateForWindow() {
        if #available(macOS 14.0, *) {
            activate()
        } else {
            activate(ignoringOtherApps: true)
        }
    }
}
