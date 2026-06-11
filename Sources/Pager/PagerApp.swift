import AppKit

@main
@MainActor
struct PagerApp {
    static func main() {
        let appDelegate = AppDelegate()
        NSApplication.shared.delegate = appDelegate
        NSApp.setActivationPolicy(.accessory) // menu-bar only, no dock icon
        NSApp.run()
    }
}
