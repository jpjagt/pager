import SwiftUI
import PagerCore

/// Create/join a pager. With `isOnboarding` it also offers Launch at Login.
struct AddPagerView: View {
    let isOnboarding: Bool
    let store: LinkStore
    let transport: SyncTransport?
    @ObservedObject var updates: UpdateController
    var onDone: (() -> Void)?

    @State private var screen: Screen = .landing
    @State private var generated = ShareCode.generate()
    @State private var createdLinkId: UUID?
    @State private var joinInput = ""
    @State private var joinedCode: ShareCode?
    @State private var joinedLinkId: UUID?
    @State private var friendMessage: String?
    @State private var firstMessage = ""
    @State private var reply = ""
    @State private var errorText: String?
    @State private var busy = false
    @State private var copied = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    enum Screen { case landing, invite, join, joined }

    /// Present only when running from the packaged app bundle.
    private static let logo: NSImage? = Bundle.main.image(forResource: "pager-logo")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch screen {
            case .landing: landingScreen
            case .invite: inviteScreen
            case .join: joinScreen
            case .joined: joinedScreen
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
    }

    // MARK: Landing

    private var landingScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                if let logo = Self.logo {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("pager")
                        .font(.title2.bold())
                    Text("share a line of thought.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 8) {
                Button {
                    create()
                } label: {
                    Text(busy ? "creating your pager…" : "invite your friend")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(busy)

                Button {
                    errorText = nil
                    screen = .join
                } label: {
                    Text("enter an invite from your friend")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(busy)
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
                Toggle("Automatically check for updates (recommended)",
                       isOn: $updates.automaticallyChecksForUpdates)
            }
        }
    }

    // MARK: Invite (pager already created)

    private var inviteScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("your invite code")
                    .font(.title2.bold())
                Text("send it to your friend privately — it's the address *and* the encryption key.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(generated.display)
                    .font(.system(.title3, design: .monospaced).bold())
                    .textSelection(.enabled)
                Spacer()
                Button(copied ? "copied!" : "copy code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(generated.display, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("waiting for your friend to connect…")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("while you wait, leave your first message:")
                    .font(.callout)
                TextField("say hi…", text: $firstMessage)
                    .textFieldStyle(.roundedBorder)
                Text("it'll be waiting in their menu bar the moment they connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }

            Button(buttonLabelForInvite) { finishInvite() }
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
        }
    }

    private var buttonLabelForInvite: String {
        if busy { return "sending…" }
        return trimmed(firstMessage).isEmpty ? "done" : "send & done"
    }

    // MARK: Join

    private var joinScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                screen = .landing
                joinInput = ""
                errorText = nil
            } label: {
                Label("back", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Text("paste your friend's code")
                .font(.title2.bold())

            TextField("ABCD-EFGH-JKLM-NPQR", text: $joinInput)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .onChange(of: joinInput) { _ in errorText = nil }

            if ShareCode.parse(joinInput) != nil {
                Button(busy ? "connecting…" : "start syncing") { join() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            } else if joinInputLooksComplete {
                Text("that code doesn't look right — check for typos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// Enough characters typed that a valid code should have parsed by now.
    private var joinInputLooksComplete: Bool {
        joinInput.filter { $0 != "-" && $0 != " " }.count >= 16
    }

    // MARK: Joined (linked, showing the friend's message — if any)

    private var joinedScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("you're linked ✨")
                .font(.title2.bold())

            if let friendMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text("your friend already left you a message:")
                        .font(.callout)
                    Text(friendMessage)
                        .font(.title3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    Text("it's in your menu bar now — that's where it lives.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("your shared line is empty for now — why not go first?")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(friendMessage == nil
                    ? "write something — it'll appear right in their menu bar."
                    : "send one back — it'll appear right in their menu bar.")
                    .font(.callout)
                TextField("say hi…", text: $reply)
                    .textFieldStyle(.roundedBorder)
            }

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button(busy ? "sending…" : "send") { sendReply() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || trimmed(reply).isEmpty)
                Button("skip for now") { onDone?() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(busy)
            }
        }
    }

    // MARK: Actions

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeActions() -> PagerActions? {
        transport.map { PagerActions(transport: $0, store: store) }
    }

    private func create() {
        guard let actions = makeActions() else {
            errorText = "Pager is not configured with a database URL."
            return
        }
        busy = true
        errorText = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                createdLinkId = try await actions.createPager(code: generated).id
                screen = .invite
            } catch {
                errorText = "Could not reach the server. Check your connection and try again."
            }
        }
    }

    private func finishInvite() {
        let message = trimmed(firstMessage)
        guard !message.isEmpty, let linkId = createdLinkId else {
            onDone?()
            return
        }
        busy = true
        errorText = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await makeActions()?.send(text: message, code: generated, linkId: linkId)
                onDone?()
            } catch {
                errorText = "Could not send — check your connection and try again."
            }
        }
    }

    private func join() {
        guard ShareCode.parse(joinInput) != nil else { return }
        guard let actions = makeActions() else {
            errorText = "Pager is not configured with a database URL."
            return
        }
        busy = true
        errorText = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let result = try await actions.joinPager(joinInput)
                joinedCode = result.link.shareCode
                joinedLinkId = result.link.id
                friendMessage = result.friendMessage
                screen = .joined
            } catch PagerActionError.alreadyLinked {
                errorText = "You already have this pager."
            } catch PagerActionError.nodeNotFound {
                errorText = "No pager exists for this code. Ask your BFF to re-send it."
            } catch PagerActionError.invalidCode {
                // The button only appears once the code parses, so this is rare.
                errorText = "That code doesn't look right — check for typos."
            } catch {
                errorText = "Could not reach the server. Check your connection and try again."
            }
        }
    }

    private func sendReply() {
        let message = trimmed(reply)
        guard !message.isEmpty, let code = joinedCode, let linkId = joinedLinkId else { return }
        busy = true
        errorText = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await makeActions()?.send(text: message, code: code, linkId: linkId)
                onDone?()
            } catch {
                errorText = "Could not send — check your connection and try again."
            }
        }
    }
}
