import SwiftUI
import PagerCore

/// Create/join a pager. With `isOnboarding` it also offers Launch at Login.
struct AddPagerView: View {
    let isOnboarding: Bool
    let store: LinkStore
    let transport: SyncTransport?
    var onDone: (() -> Void)?

    @State private var mode: Mode = .create
    @State private var generated = ShareCode.generate()
    @State private var joinInput = ""
    @State private var errorText: String?
    @State private var busy = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    enum Mode { case create, join }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isOnboarding {
                Text("Welcome to Pager 📟")
                    .font(.title2.bold())
                Text("One shared line of text in your menu bar — synced with your BFF, end-to-end encrypted.")
                    .foregroundStyle(.secondary)
            }

            Picker("", selection: $mode) {
                Text("Create a pager").tag(Mode.create)
                Text("Join with code").tag(Mode.join)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .create:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Send this code to your BFF — it's the address *and* the encryption key, so share it privately:")
                        .font(.callout)
                    HStack {
                        Text(generated.display)
                            .font(.system(.title3, design: .monospaced).bold())
                            .textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(generated.display, forType: .string)
                        }
                    }
                    Button(busy ? "Creating…" : "Create pager") { create() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy)
                }
            case .join:
                VStack(alignment: .leading, spacing: 8) {
                    TextField("ABCD-EFGH-JKLM-NPQR", text: $joinInput)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    Button(busy ? "Joining…" : "Join pager") { join() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || joinInput.isEmpty)
                }
            }

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }

            if isOnboarding {
                Divider()
                Toggle("Launch Pager at login (recommended)", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { value in
                        LaunchAtLogin.set(value)
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func create() {
        guard let transport else {
            errorText = "Pager is not configured with a database URL."
            return
        }
        busy = true
        errorText = nil
        let code = generated
        let crypto = PagerCrypto(code: code)
        let deviceId = store.deviceId
        Task { @MainActor in
            defer { busy = false }
            do {
                // Initial empty node so joiners can verify the code exists.
                let value = PagerValue(
                    ct: try crypto.encrypt(""),
                    writtenAt: Int64(Date().timeIntervalSince1970 * 1000),
                    updatedBy: deviceId)
                try await transport.put(pathId: crypto.pathId, value: value)
                store.add(code: code)
                onDone?()
            } catch {
                errorText = "Could not reach the server. Check your connection and try again."
            }
        }
    }

    private func join() {
        guard let code = ShareCode.parse(joinInput) else {
            errorText = "That code doesn't look right — check for typos."
            return
        }
        guard !store.links.contains(where: { $0.code == code.full }) else {
            errorText = "You already have this pager."
            return
        }
        guard let transport else {
            errorText = "Pager is not configured with a database URL."
            return
        }
        busy = true
        errorText = nil
        let crypto = PagerCrypto(code: code)
        Task { @MainActor in
            defer { busy = false }
            do {
                guard try await transport.get(pathId: crypto.pathId) != nil else {
                    errorText = "No pager exists for this code. Ask your BFF to re-send it."
                    return
                }
                store.add(code: code)
                onDone?()
            } catch {
                errorText = "Could not reach the server. Check your connection and try again."
            }
        }
    }
}
