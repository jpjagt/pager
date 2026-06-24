import AppKit
import PagerCore

/// Opens the user's mail client pre-filled, via NSSharingService. The only
/// AppKit-touching part of the debug-report flow; everything that decides
/// *what* to send lives in PagerCore (DebugReport) and is tested there.
struct SharingServiceMailComposer: MailComposer {
    func compose(_ mail: ComposedMail) -> Bool {
        guard let service = NSSharingService(named: .composeEmail) else { return false }
        service.recipients = [mail.recipient]
        service.subject = mail.subject

        var items: [Any] = [mail.body]
        if let attachment = mail.attachment,
           FileManager.default.fileExists(atPath: attachment.path) {
            items.append(attachment)
        }
        guard service.canPerform(withItems: items) else { return false }
        service.perform(withItems: items)
        return true
    }
}
