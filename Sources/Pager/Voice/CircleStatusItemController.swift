import AppKit
import VoiceCore

/// One `NSStatusItem` per circle — and, per the design, the circle's entire
/// UI: an LED dot inside a neutral ring, steady colors only, plus elapsed
/// time as text while recording. Clicking opens the menu (the mouse's route
/// to the hotkey verbs).
@MainActor
final class CircleStatusItemController: NSObject, NSMenuDelegate {
    let circleId: UUID
    private let statusItem: NSStatusItem
    private var led: VoiceEngine.Led = .offline
    private var appearanceObserver: NSKeyValueObservation?
    private var recordingTimer: Timer?
    private var recordingStarted: Date?

    /// Menu verbs, wired by AppDelegate to the engine.
    var onPlay: (() -> Void)?
    var onRecordToggle: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onUnlink: (() -> Void)?
    var onSettings: (() -> Void)?
    /// State the menu renders from.
    var menuState: (() -> (nickname: String, unheard: Int, playing: Bool,
                           recording: Bool, shortcut: KeyBinding?))?

    init(circleId: UUID) {
        self.circleId = circleId
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        if let button = statusItem.button {
            appearanceObserver = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                guard let self else { return }
                Task { @MainActor in self.redraw() }
            }
        }
        redraw()
    }

    func removeFromStatusBar() {
        recordingTimer?.invalidate()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - LED

    func render(_ led: VoiceEngine.Led) {
        self.led = led
        if case .recording = led {
            if recordingStarted == nil {
                recordingStarted = Date()
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.redraw() }
                }
                RunLoop.main.add(timer, forMode: .common)
                recordingTimer = timer
            }
        } else {
            recordingTimer?.invalidate()
            recordingTimer = nil
            recordingStarted = nil
        }
        redraw()
    }

    private func redraw() {
        guard let button = statusItem.button else { return }
        let dark = button.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        button.image = Self.image(for: led, darkMenuBar: dark)
        if case .recording = led, let started = recordingStarted {
            let seconds = Int(Date().timeIntervalSince(started))
            button.imagePosition = .imageLeft
            button.attributedTitle = NSAttributedString(
                string: String(format: "%d:%02d", seconds / 60, seconds % 60),
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: Self.ledColor(for: .recording),
                ])
        } else {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    static func ledColor(for led: VoiceEngine.Led) -> NSColor {
        switch led {
        case .recording: return NSColor(calibratedRed: 0.92, green: 0.26, blue: 0.21, alpha: 1)
        case .uploading: return NSColor(calibratedRed: 0.92, green: 0.26, blue: 0.21, alpha: 0.5)
        case .playing: return NSColor(calibratedWhite: 0.98, alpha: 1)
        case .incoming: return NSColor(calibratedRed: 0.55, green: 0.53, blue: 0.95, alpha: 1) // lavender-blue: a live transmission
        case .unheard: return NSColor(calibratedRed: 0.24, green: 0.82, blue: 0.44, alpha: 1)
        case .offline, .idle: return .clear
        }
    }

    /// The glyph: LED dot, transparent gap, thin neutral ring. 18 pt square
    /// (the standard template-icon box); colors are literal, so the image is
    /// rebuilt per menu-bar appearance instead of being a template.
    static func image(for led: VoiceEngine.Led, darkMenuBar: Bool) -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let center = NSPoint(x: size / 2, y: size / 2)
            let ringAlpha: CGFloat = {
                if case .offline = led { return 0.25 } // dimmed ring: no connection
                return 0.55
            }()
            let ink = NSColor(calibratedWhite: darkMenuBar ? 0.95 : 0.1, alpha: ringAlpha)
            let ringRect = NSRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)
            let ring = NSBezierPath(ovalIn: ringRect)
            ring.lineWidth = 1.5
            ink.setStroke()
            ring.stroke()

            let color = ledColor(for: led)
            let isOff = color == .clear
            let ledRect = NSRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)
            let dot = NSBezierPath(ovalIn: ledRect)
            if isOff {
                // Idle: a faint unlit dot, so the glyph still reads as an LED.
                NSColor(calibratedWhite: darkMenuBar ? 0.95 : 0.1, alpha: 0.18).setFill()
            } else {
                color.setFill()
            }
            dot.fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let state = menuState?() else { return }

        let title = NSMenuItem(title: state.nickname, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        if let shortcut = state.shortcut {
            let hint = NSMenuItem(
                title: "tap \(HotkeyCenter.describe(shortcut)) to play · hold to record",
                action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        menu.addItem(.separator())

        if state.recording {
            menu.addItem(makeItem("send recording", #selector(recordClicked)))
            menu.addItem(makeItem("discard recording", #selector(discardClicked)))
        } else {
            let playTitle = state.playing
                ? "stop"
                : (state.unheard > 0 ? "play unheard (\(state.unheard))" : "replay latest")
            menu.addItem(makeItem(playTitle, #selector(playClicked)))
            menu.addItem(makeItem("record message", #selector(recordClicked)))
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("settings…", #selector(settingsClicked)))
        menu.addItem(makeItem("unlink this locket…", #selector(unlinkClicked)))
        menu.addItem(.separator())
        menu.addItem(makeItem("quit pager", #selector(NSApplication.terminate(_:)), target: NSApp))
    }

    private func makeItem(_ title: String, _ action: Selector,
                          target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target ?? self
        return item
    }

    @objc private func playClicked() { onPlay?() }
    @objc private func recordClicked() { onRecordToggle?() }
    @objc private func discardClicked() { onDiscard?() }
    @objc private func unlinkClicked() { onUnlink?() }
    @objc private func settingsClicked() { onSettings?() }
}
