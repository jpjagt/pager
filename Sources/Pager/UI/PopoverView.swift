import SwiftUI
import PagerCore

struct PopoverView: View {
    @ObservedObject var model: LinkViewModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                Button { model.onClose?() } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Menu {
                    Button("Settings…") { model.onOpenSettings?() }
                    Divider()
                    Button("Quit Pager") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }

            TextField("Type something…", text: $model.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .lineLimit(1...5)
                .focused($focused)
                .onChange(of: model.text) { _ in model.textEdited() }

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
    }
}
