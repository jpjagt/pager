import SwiftUI
import UniformTypeIdentifiers
import PagerCore
import PagerUI

/// Drops onto the pager *window* (the device itself), as opposed to onto the
/// menu bar item. Same classifier, different semantics: a window drop becomes
/// the **draft** — exactly what ⌘V does — so it can be reviewed, cleared or
/// abandoned before it goes anywhere. A menu-bar drop still means "send this".
///
/// A `DropDelegate` rather than the closure form of `.onDrop` because only the
/// delegate is told what is hovering *before* it lands (`DropInfo`), which is
/// what lets the LCD prompt say "drop image…" versus "drop text…".
struct PagerDropDelegate: DropDelegate {
    /// Everything a pager can take. `.fileURL` is separate from `.image`
    /// because Finder drags of an image file may advertise only the URL.
    static let acceptedTypes: [UTType] = [.image, .fileURL, .text]

    /// The hovering payload kind, or nil on exit/drop — drives the drop zone.
    let onHover: (DropTargetKind?) -> Void
    /// Everything readable off the drop, in the classifier's terms.
    let onPayload: ([Data], [String]) -> Void

    func validateDrop(info: DropInfo) -> Bool { kind(for: info) != nil }

    func dropEntered(info: DropInfo) { onHover(kind(for: info)) }

    func dropExited(info: DropInfo) { onHover(nil) }

    /// Copy semantics: gives the drag the standard + badge. Returning nil here
    /// would leave the cursor showing the source's default operation (often a
    /// move), which is wrong — nothing is taken from where the file came from.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        onHover(nil)
        let providers = info.itemProviders(for: Self.acceptedTypes)
        guard !providers.isEmpty else { return false }
        // Reading a provider is asynchronous (a dropped file may not even be
        // local yet), so the drop is accepted now and the payload arrives when
        // it arrives. Everything here stays on the main actor: the loads are
        // awaited, not blocking, and the same-actor hand-off keeps the
        // (non-sendable) providers from crossing an isolation boundary.
        Task { @MainActor in
            var imageDatas: [Data] = []
            var strings: [String] = []
            for provider in providers {
                if let data = await provider.imageCandidateData() {
                    imageDatas.append(data)
                } else if let text = await provider.plainText() {
                    strings.append(text)
                }
            }
            onPayload(imageDatas, strings)
        }
        return true
    }

    /// What the drag would leave behind, decided from declared types alone —
    /// nothing is loaded on hover. A file URL is assumed to be an image (the
    /// overwhelmingly common case, and the classifier still gets the last word
    /// once the bytes are actually read).
    private func kind(for info: DropInfo) -> DropTargetKind? {
        if info.hasItemsConforming(to: [.image, .fileURL]) { return .image }
        if info.hasItemsConforming(to: [.text]) { return .text }
        return nil
    }
}

/// Main-actor-bound on purpose: `DropDelegate` is itself main-actor isolated,
/// and keeping the loads here means the (non-sendable) providers never cross an
/// isolation boundary. The awaits don't block the main thread, and the one
/// synchronous read — a dropped file's bytes — is the same read the pasteboard
/// paths already do inline.
@MainActor
private extension NSItemProvider {
    /// Bytes that might decode to an image: the file's contents for a file
    /// drag, the raw representation for a direct image drag. "Might" is the
    /// point — `DropPayloadClassifier` decides, exactly as it does for the
    /// pasteboard paths.
    func imageCandidateData() async -> Data? {
        if hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let urlData = await data(for: UTType.fileURL.identifier),
           let url = URL(dataRepresentation: urlData, relativeTo: nil),
           let contents = try? Data(contentsOf: url) {
            return contents
        }
        guard let identifier = registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) else { return nil }
        return await data(for: identifier)
    }

    func plainText() async -> String? {
        guard let identifier = registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .text) == true
        }), let bytes = await data(for: identifier) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    func data(for identifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
