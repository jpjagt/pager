import Foundation

/// Builds the subject and body of the "Email a debug report" message. Pure
/// (no AppKit, no I/O) so the formatting is unit-testable; AppDelegate gathers
/// the inputs and hands the body to the mail compose service.
struct DebugReport {
    struct LinkInfo {
        let nickname: String
        let pathPrefix: String
        let state: String
        let lastWrittenAt: Int64
        let codeDisplay: String
    }

    let appVersion: String
    let build: String
    let osVersion: String
    let deviceId: String
    let links: [LinkInfo]

    var subject: String { "Pager debug report" }

    func body(includeMessages: Bool) -> String {
        var lines = [
            "hi! pager isn't behaving. here's what's going wrong:",
            "",
            "[please share details about what's going wrong here]",
            "",
            "--- Extra debug information (please don't remove) ---",
            "Pager version: \(appVersion) (build \(build))",
            "macOS version: \(osVersion)",
            "Device: \(deviceId)",
            "Links (\(links.count)):",
        ]
        for link in links {
            lines.append("  • \"\(link.nickname)\"  path \(link.pathPrefix)  "
                + "state \(link.state)  lastWrittenAt \(link.lastWrittenAt)")
        }
        if includeMessages, !links.isEmpty {
            lines.append("")
            lines.append("Pager codes (you chose to include these so the app developer can read your messages):")
            for link in links {
                lines.append("  • \"\(link.nickname)\": \(link.codeDisplay)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
