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
        VStack(alignment: .leading, spacing: 16) {
            ForEach(store.links) { link in
                LinkSettingsRow(
                    link: link,
                    onChange: { store.updateMeta(id: $0.id, nickname: $0.nickname, appearance: $0.appearance) },
                    onUnlink: { confirmUnlink = link })
                Divider()
            }

            Button("add a pager…") { onAddPager?() }

            Divider()
            settingsSection

            Divider()
            debugSection
        }
        .padding(20)
        .frame(width: 440)
        .alert("no mail account configured", isPresented: $showNoMailAlert) {
            Button("ok", role: .cancel) {}
        } message: {
            Text("set up Mail (or another mail app) to send a debug report, or contact \(PagerConfig.supportEmail) directly.")
        }
        .alert(item: $confirmUnlink) { link in
            Alert(
                title: Text("unlink \(link.nickname)?"),
                message: Text("this removes the pager from this device only. your BFF keeps theirs."),
                primaryButton: .destructive(Text("unlink")) { store.remove(id: link.id) },
                secondaryButton: .cancel())
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("settings").font(.headline)
            Toggle("launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { value in
                    LaunchAtLogin.set(value)
                    launchAtLogin = LaunchAtLogin.isEnabled
                }
            Toggle("automatically check for updates", isOn: $updates.automaticallyChecksForUpdates)
            if updates.updateAvailable {
                Button("update available — install \(updates.availableVersion ?? "")") {
                    updates.installUpdate()
                }
            } else {
                Button("check for updates…") { updates.checkForUpdates() }
            }
            HStack {
                Button("quit pager") { NSApp.terminate(nil) }
                Spacer()
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
            Toggle("include the messages that were sent and received on your pagers",
                   isOn: $includeMessages)
                .font(.caption)
            Button("email a debug report") {
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
                TextField("nickname", text: $link.nickname)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit { onChange(link) }
                Spacer()
                Button("unlink", role: .destructive) { onUnlink() }
            }
            HStack(spacing: 8) {
                Text(link.shareCode.display)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("copy code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.shareCode.display, forType: .string)
                }
                .controlSize(.small)
            }
            HStack {
                Text("max width")
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
                Text("text size")
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
                Text("opacity")
                Slider(
                    value: Binding(
                        get: { link.appearance.opacity },
                        set: { link.appearance.opacity = $0; onChange(link) }),
                    in: 0.2...1)
                Text("\(Int(link.appearance.opacity * 100)) %")
                    .font(.caption).monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            HStack(alignment: .top) {
                Text("screen color")
                Spacer()
                HStack(spacing: 8) {
                    ForEach(ScreenColor.allCases, id: \.self) { color in
                        SwatchButton(
                            hex: color.palette.backlight,
                            isSelected: link.appearance.screenColor == color,
                            action: {
                                link.appearance.screenColor = color
                                onChange(link)
                            })
                    }
                }
            }
            HStack(alignment: .top) {
                Text("case color")
                Spacer()
                HStack(spacing: 8) {
                    ForEach(CaseColor.allCases, id: \.self) { color in
                        SwatchButton(
                            hex: color.palette.shellTop,
                            isSelected: link.appearance.caseColor == color,
                            action: {
                                link.appearance.caseColor = color
                                onChange(link)
                            })
                    }
                }
            }
        }
    }
}

/// A single round color swatch used by the screen/case color rows. Renders
/// the actual theme color and an unambiguous selected ring — not a subtle
/// tint — since the whole point is to make the choice visible at a glance.
private struct SwatchButton: View {
    let hex: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: TextUtil.color(fromHex: hex) ?? .labelColor))
                .frame(width: 20, height: 20)
                .overlay(
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2.5 : 0)
                        .padding(-2.5)
                )
        }
        .buttonStyle(.plain)
    }
}
