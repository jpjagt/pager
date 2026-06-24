import SwiftUI
import PagerCore

struct PopoverView: View {
    @ObservedObject var model: LinkViewModel
    @ObservedObject var updates: UpdateController
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Spacer()
                if updates.updateAvailable {
                    Button { updates.installUpdate() } label: {
                        Text("Update now").font(.caption).underline()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
                Button { model.onClose?() } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Menu {
                    Button("settings…") { model.onOpenSettings?() }
                    Divider()
                    Button("quit pager") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .foregroundStyle(.secondary)
                .fixedSize()
            }

            TextField("type a message…", text: $model.text)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($focused)
                .onChange(of: model.text) { _ in model.textEdited() }
                .onSubmit { model.onClose?() } // Enter commits + closes the popover

            if !model.detectedURLs.isEmpty {
                HStack(spacing: 12) {
                    ForEach(Array(model.detectedURLs.enumerated()), id: \.offset) { _, match in
                        Link(match.url.absoluteString, destination: match.url)
                            .font(.caption)
                            .underline()
                    }
                }
            }

            if model.showOfflineHint {
                Text("offline, will sync when back online")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { focused = true }
        .onDisappear { model.commit() } // fires on both close paths: button and click-away
    }
}
