import SwiftUI
import PagerCore

/// One shared settings window: all links with per-link options, then app-wide.
struct SettingsView: View {
    @ObservedObject var store: LinkStore
    @ObservedObject var updates: UpdateController
    var onAddPager: (() -> Void)?
    /// Returns false if no mail account is configured (so we can tell the user).
    var onEmailDebugReport: ((_ includeMessages: Bool) -> Bool)?

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var confirmUnlink: PagerLink?
    @State private var includeMessages = false
    @State private var showNoMailAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(store.links) { link in
                    LinkSettingsRow(
                        link: link,
                        onChange: { store.updateMeta(id: $0.id, nickname: $0.nickname, appearance: $0.appearance) },
                        onUnlink: { confirmUnlink = link })
                    Divider()
                }

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { value in
                        LaunchAtLogin.set(value)
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                HStack {
                    Button("Add a pager…") { onAddPager?() }
                    Spacer()
                    Button("Quit Pager") { NSApp.terminate(nil) }
                }

                Divider()
                updatesSection

                Divider()
                debugSection
            }
            .padding(20)
        }
        .frame(width: 440, height: 420)
        .alert("No mail account configured", isPresented: $showNoMailAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Set up Mail (or another mail app) to send a debug report, or contact \(PagerConfig.supportEmail) directly.")
        }
        .alert(item: $confirmUnlink) { link in
            Alert(
                title: Text("Unlink \(link.nickname)?"),
                message: Text("This removes the pager from this device only. Your BFF keeps theirs."),
                primaryButton: .destructive(Text("Unlink")) { store.remove(id: link.id) },
                secondaryButton: .cancel())
        }
    }

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updates.automaticallyChecksForUpdates },
                set: { updates.automaticallyChecksForUpdates = $0 }))
            if updates.updateAvailable {
                Button("Update available — install \(updates.availableVersion ?? "")") {
                    updates.installUpdate()
                }
            } else {
                Button("Check for Updates…") { updates.checkForUpdates() }
            }
        }
    }

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("something not syncing? send a debug report to pager's app developer. "
                + "it attaches a technical log of recent sync activity. your messages stay "
                + "encrypted in the log — they can only be read if you opt in below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Include the messages that were sent and received on your pagers",
                   isOn: $includeMessages)
                .font(.caption)
            Button("Email a debug report") {
                if onEmailDebugReport?(includeMessages) == false { showNoMailAlert = true }
            }
        }
    }
}

private struct LinkSettingsRow: View {
    @State var link: PagerLink
    var onChange: (PagerLink) -> Void
    var onUnlink: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Nickname", text: $link.nickname)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit { onChange(link) }
                Spacer()
                Button("Unlink", role: .destructive) { onUnlink() }
            }
            HStack(spacing: 8) {
                Text(link.shareCode.display)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Copy code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.shareCode.display, forType: .string)
                }
                .controlSize(.small)
            }
            HStack {
                Text("Max width")
                Slider(
                    value: Binding(
                        get: { link.appearance.maxWidth },
                        set: { link.appearance.maxWidth = $0; onChange(link) }),
                    in: 60...600)
                Text("\(Int(link.appearance.maxWidth)) pt")
                    .font(.caption).monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            HStack {
                Text("Text size")
                Slider(
                    value: Binding(
                        get: { link.appearance.fontSize },
                        set: { link.appearance.fontSize = $0; onChange(link) }),
                    in: 9...18, step: 1)
                Text("\(Int(link.appearance.fontSize)) pt")
                    .font(.caption).monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            HStack {
                Text("Opacity")
                Slider(
                    value: Binding(
                        get: { link.appearance.opacity },
                        set: { link.appearance.opacity = $0; onChange(link) }),
                    in: 0.2...1)
                Text("\(Int(link.appearance.opacity * 100)) %")
                    .font(.caption).monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            HStack {
                ColorPicker(
                    "Color",
                    selection: Binding(
                        get: {
                            Color(nsColor: link.appearance.colorHex
                                .flatMap(TextUtil.color(fromHex:)) ?? .labelColor)
                        },
                        set: {
                            link.appearance.colorHex = TextUtil.hex(from: NSColor($0))
                            onChange(link)
                        }),
                    supportsOpacity: false)
                Button("Default color") {
                    link.appearance.colorHex = nil
                    onChange(link)
                }
                .controlSize(.small)
            }
        }
    }
}
