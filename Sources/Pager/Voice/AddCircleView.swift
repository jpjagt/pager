import SwiftUI
import AppKit
import Carbon.HIToolbox
import VoiceCore

/// "Add voice locket…" — paste a claim token, provision, pick the shortcut.
/// A thin shell over `VoiceActions.enroll`, native macOS like `AddPagerView`.
struct AddCircleView: View {
    let circles: CircleStore
    let identityStore: KeychainIdentityStore
    var onDone: (() -> Void)?

    @State private var serverURL = ""
    @State private var claimToken = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var enrolled: VoiceCircle?
    @State private var displacedNickname: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("add a voice locket").font(.headline)

            if let enrolled {
                enrolledSection(enrolled)
            } else {
                enrollSection
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var enrollSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("join a voice circle as a new device of your account. "
                + "mint a claim token from your account and paste it here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("server, e.g. https://voice.example.com", text: $serverURL)
                .textFieldStyle(.roundedBorder)
            TextField("claim token", text: $claimToken)
                .textFieldStyle(.roundedBorder)

            Text("voice circles are not end-to-end encrypted; the server processes audio. "
                + "(pagers stay E2E-encrypted as always.)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("cancel") { onDone?() }
                Button(busy ? "joining…" : "join circle") { enroll() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || claimToken.isEmpty || serverURL.isEmpty)
            }
        }
    }

    private func enrolledSection(_ circle: VoiceCircle) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("joined \(circle.config.circleId) as \(circle.config.deviceId).")
                .font(.caption)
            HStack {
                Text("shortcut")
                KeyCaptureField(binding: Binding(
                    get: { circles.circles.first { $0.id == circle.id }?.shortcut },
                    set: { newBinding in
                        let displaced = circles.bind(newBinding, to: circle.id)
                        displacedNickname = displaced?.nickname
                    }))
                    .frame(width: 120, height: 24)
            }
            if let displacedNickname {
                Text("moved the shortcut from \(displacedNickname) — bind it a new one in settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("tap the shortcut to play · hold it to record")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("done") { onDone?() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func enroll() {
        busy = true
        errorText = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                enrolled = try await VoiceActions.enroll(
                    serverURL: serverURL, claimToken: claimToken,
                    circles: circles, identityStore: identityStore)
            } catch VoiceActions.EnrollError.badServerURL {
                errorText = "that server URL doesn't look right."
            } catch ProvisioningError.rejected(let status) {
                errorText = "the server refused the claim token (\(status))."
            } catch {
                errorText = "couldn't reach the server. check the URL and try again."
            }
        }
    }
}

/// Click, then press a combo — captured as a Carbon-ready `KeyBinding`.
/// Plain keys without modifiers are refused (a global hotkey on a bare
/// letter would swallow normal typing system-wide).
struct KeyCaptureField: NSViewRepresentable {
    @Binding var binding: KeyBinding?

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onCapture = { binding = $0 }
        view.current = binding
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.current = binding
    }

    final class CaptureView: NSView {
        var onCapture: ((KeyBinding) -> Void)?
        var current: KeyBinding? {
            didSet { needsDisplay = true }
        }
        private var capturing = false {
            didSet { needsDisplay = true }
        }

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            capturing = true
        }

        override func resignFirstResponder() -> Bool {
            capturing = false
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard capturing else { return super.keyDown(with: event) }
            var modifiers: UInt32 = 0
            if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
            if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
            if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            guard modifiers != 0 else { NSSound.beep(); return }
            let captured = KeyBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            capturing = false
            onCapture?(captured)
            window?.makeFirstResponder(nil)
        }

        override func draw(_ dirtyRect: NSRect) {
            let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                          xRadius: 5, yRadius: 5)
            (capturing ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25)
                       : NSColor.quaternaryLabelColor.withAlphaComponent(0.2)).setFill()
            background.fill()
            let text = capturing
                ? "press keys…"
                : current.map { HotkeyCenter.describe($0) } ?? "click to set"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2,
                                  y: bounds.midY - size.height / 2),
                      withAttributes: attributes)
        }
    }
}
