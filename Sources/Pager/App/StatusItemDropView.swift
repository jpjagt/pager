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
        guard let payload = PasteboardPayload.read(sender.draggingPasteboard) else {
            NSSound.beep()
            return false
        }
        onDrop?(payload)
        return true
    }
}
