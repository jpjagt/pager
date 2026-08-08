import AppKit
import PagerCore

/// Reads everything a pager cares about off an `NSPasteboard` and hands it to
/// `DropPayloadClassifier`. The AppKit half of what the classifier decides —
/// which is why it lives here and not in `PagerCore`.
///
/// One reader for both entry points that see a pasteboard: a drag onto the menu
/// bar item (`StatusItemDropView`) and ⌘V into an open pager
/// (`LinkViewModel.pasteFromGeneralPasteboard`). Window drops don't come through
/// here — SwiftUI hands those over as `NSItemProvider`s (`PagerDropDelegate`).
enum PasteboardPayload {
    /// Direct image data, image *files*, then text — the order the classifier
    /// resolves them in (image beats text; first decodable image wins).
    static func read(_ pasteboard: NSPasteboard) -> DropPayload? {
        var imageDatas: [Data] = []
        // Direct image data (browser drags, screenshot floats).
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { imageDatas.append(data) }
        }
        // Dropped/copied files (Finder): read contents; the classifier decides
        // if they're images. Non-image files simply won't classify.
        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        for url in fileURLs {
            if let data = try? Data(contentsOf: url) { imageDatas.append(data) }
        }
        let strings = pasteboard.readObjects(forClasses: [NSString.self]) as? [String] ?? []
        return DropPayloadClassifier.classify(imageDatas: imageDatas, strings: strings)
    }
}
