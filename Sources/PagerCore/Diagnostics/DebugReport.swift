import Foundation

/// Builds the subject and body of the "Email a debug report" message. Pure
/// (no AppKit, no I/O) so the formatting is unit- and E2E-testable; callers
/// gather the inputs and hand the result to a MailComposer.
public struct DebugReport: Equatable {
    public struct LinkInfo: Equatable {
        public let nickname: String
        public let pathPrefix: String
        public let state: String
        public let lastWrittenAt: Int64
        public let codeDisplay: String

        public init(nickname: String, pathPrefix: String, state: String,
                    lastWrittenAt: Int64, codeDisplay: String) {
            self.nickname = nickname
            self.pathPrefix = pathPrefix
            self.state = state
            self.lastWrittenAt = lastWrittenAt
            self.codeDisplay = codeDisplay
        }
    }

    public let appVersion: String
    public let build: String
    public let osVersion: String
    public let deviceId: String
    public let links: [LinkInfo]

    public init(appVersion: String, build: String, osVersion: String,
                deviceId: String, links: [LinkInfo]) {
        self.appVersion = appVersion
        self.build = build
        self.osVersion = osVersion
        self.deviceId = deviceId
        self.links = links
    }

    public var subject: String { "pager debug report" }

    public func body(includeMessages: Bool) -> String {
        var lines = [
            "hi! pager isn't behaving. here's what's going wrong:",
            "",
            "[please share details about what's going wrong here]",
            "",
            "",
            "--- Extra debug information (please don't remove) ---",
            "Pager version: \(appVersion) (build \(build))",
            "macOS version: \(osVersion)",
            "Device: \(deviceId)",
            "",
            "Links (\(links.count)):",
        ]
        for link in links {
            lines.append("  - \"\(link.nickname)\": path=\(link.pathPrefix), "
                           + "state=\(link.state), lastWrittenAt=\(link.lastWrittenAt)")
        }
        if includeMessages, !links.isEmpty {
            lines.append("")
            lines.append("Pager codes (you chose to include these so the app developer can read your messages - remove if you don't want this):")
            for link in links {
                lines.append("  - \"\(link.nickname)\": \(link.codeDisplay)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Assembles a DebugReport from the live link store + per-link engine states,
/// so the app and the E2E harness build identical reports.
public enum DebugReportFactory {
    public static func make(store: LinkStore, states: [UUID: String],
                            appVersion: String, build: String, osVersion: String) -> DebugReport {
        DebugReport(
            appVersion: appVersion, build: build, osVersion: osVersion,
            deviceId: store.deviceId,
            links: store.links.map { link in
                DebugReport.LinkInfo(
                    nickname: link.nickname,
                    pathPrefix: String(PagerCrypto(code: link.shareCode).pathId.prefix(8)),
                    state: states[link.id] ?? "offline",
                    lastWrittenAt: link.cachedWrittenAt,
                    codeDisplay: link.shareCode.display)
            })
    }
}

/// A fully-composed mail message. The actual send is abstracted behind
/// MailComposer so the assembly (recipient/subject/body/attachment) is testable
/// without opening Mail.app.
public struct ComposedMail: Equatable {
    public let recipient: String
    public let subject: String
    public let body: String
    public let attachment: URL?

    public init(recipient: String, subject: String, body: String, attachment: URL?) {
        self.recipient = recipient
        self.subject = subject
        self.body = body
        self.attachment = attachment
    }
}

public protocol MailComposer {
    /// Hands the message to the user's mail client. Returns false if none is
    /// available (so the UI can explain why nothing happened).
    func compose(_ mail: ComposedMail) -> Bool
}
