import SwiftUI
import UniformTypeIdentifiers
import PagerCore

struct PopoverView: View {
    @ObservedObject var model: LinkViewModel
    @ObservedObject var updates: UpdateController
    @ObservedObject var previews: ImageURLPreviewLoader
    @FocusState private var focused: Bool

    init(model: LinkViewModel, updates: UpdateController) {
        self.model = model
        self.updates = updates
        self.previews = model.previewLoader
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Spacer()
                if updates.updateAvailable {
                    Button {
                        model.onClose?() // let the popover go before Sparkle's window arrives
                        updates.installUpdate()
                    } label: {
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
                .onPasteCommand(of: [UTType.image, UTType.fileURL]) { _ in
                    model.pasteFromGeneralPasteboard()
                }

            if !model.detectedURLs.isEmpty {
                HStack(spacing: 12) {
                    ForEach(Array(model.detectedURLs.enumerated()), id: \.offset) { _, match in
                        Link(match.url.absoluteString, destination: match.url)
                            .font(.caption)
                            .underline()
                    }
                }
            }

            if let error = model.imageError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let draft = model.draftImage {
                PagerImageView(
                    imageData: draft,
                    onTap: { model.openDraftImage() },
                    onClear: { model.clearImage() })
            } else if let preview = previews.preview {
                PagerImageView(
                    imageData: preview.data,
                    onTap: { NSWorkspace.shared.open(preview.url) },
                    onClear: nil)
            }

            if model.showOfflineHint {
                Text("offline, will sync when back online")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            focused = true
            model.installPasteMonitor()
        }
    }
}
