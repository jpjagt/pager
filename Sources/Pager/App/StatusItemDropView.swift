import AppKit
import PagerCore

/// Transparent overlay filling the status item button: accepts drags (image
/// data, image files, text) and reports the classified payload. Mouse clicks
/// are forwarded to the button underneath so the popover toggle still works.
final class StatusItemDropView: NSView {
    var onDrop: ((DropPayload) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff, .string])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) {
        superview?.mouseDown(with: event) // let the NSStatusBarButton handle clicks
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        var imageDatas: [Data] = []
        // Direct image data (browser drags, screenshot floats).
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { imageDatas.append(data) }
        }
        // Dropped files (Finder): read contents; the classifier decides if
        // they're images. Non-image files simply won't classify.
        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        for url in fileURLs {
            if let data = try? Data(contentsOf: url) { imageDatas.append(data) }
        }
        let strings = pasteboard.readObjects(forClasses: [NSString.self]) as? [String] ?? []
        guard let payload = DropPayloadClassifier.classify(
            imageDatas: imageDatas, strings: strings) else {
            NSSound.beep()
            return false
        }
        onDrop?(payload)
        return true
    }
}
