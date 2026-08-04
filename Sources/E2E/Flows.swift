import Foundation
import PagerCore

/// Captures the composed mail instead of opening Mail.app — the standard way
/// to test a share/compose flow without driving another process.
final class CapturingMailComposer: MailComposer, @unchecked Sendable {
    private(set) var last: ComposedMail?
    func compose(_ mail: ComposedMail) -> Bool { last = mail; return true }
}

/// A headless stand-in for one running app: an isolated UserDefaults suite +
/// LinkStore + PagerActions + engines + a capturing mail composer. Two of these
/// against real Firebase reproduce "add a pager on A, join on B, converse".
@MainActor
final class Device {
    let store: LinkStore
    let actions: PagerActions
    let mail = CapturingMailComposer()
    private let transport: SyncTransport
    private let suiteName: String
    private var engines: [UUID: SyncEngine] = [:]
    /// Last value pushed to each link (remote changes only — own writes echo).
    var received: [UUID: String] = [:]

    init(name: String, transport: SyncTransport) {
        self.transport = transport
        self.suiteName = "e2e-\(name)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName) // clean slate, never touches .standard
        self.store = LinkStore(defaults: defaults)
        self.actions = PagerActions(transport: transport, store: store)
    }

    func connect() {
        for link in store.links where engines[link.id] == nil {
            let crypto = PagerCrypto(code: link.shareCode)
            let engine = SyncEngine(transport: transport, crypto: crypto,
                                    pathId: crypto.pathId, deviceId: store.deviceId)
            let id = link.id
            engine.onContent = { [weak self] content, _ in self?.received[id] = content.textValue }
            engines[id] = engine
            engine.start()
        }
    }

    func disconnect() {
        engines.values.forEach { $0.stop() }
        engines.removeAll()
    }

    /// Mirrors AppDelegate.sendDebugReport, minus the AppKit composer.
    @discardableResult
    func sendDebugReport(includeMessages: Bool) -> Bool {
        let report = DebugReportFactory.make(
            store: store, states: [:], appVersion: "e2e", build: "0", osVersion: "0.0.0")
        return mail.compose(ComposedMail(
            recipient: PagerConfig.supportEmail, subject: report.subject,
            body: report.body(includeMessages: includeMessages), attachment: nil))
    }

    func cleanup() {
        disconnect()
        UserDefaults().removePersistentDomain(forName: suiteName)
    }
}

@MainActor
enum Flows {
    /// Drives the full app-level flow across two isolated devices, reporting
    /// each assertion through `check`. Cleans up the node it creates.
    static func run(transport: FirebaseClient, dbURL: URL, check: (String, Bool) -> Void) async {
        let a = Device(name: "A", transport: transport)
        let b = Device(name: "B", transport: transport)

        // 1. A creates a pager and leaves a first message.
        guard let link = try? await a.actions.createPager() else {
            check("A creates a pager", false); a.cleanup(); b.cleanup(); return
        }
        let code = link.shareCode
        check("A creates a pager (link persisted)", a.store.links.count == 1)
        try? await a.actions.send(text: "first-hi", code: code, linkId: link.id)

        // 2. B joins with A's code and sees the waiting message.
        let join = try? await b.actions.joinPager(code.display)
        check("B joins with A's code", join != nil && b.store.links.count == 1)
        check("B sees A's waiting message on join", join?.friendMessage == "first-hi")
        check("B caches the joined message", b.store.links.first?.cachedText == "first-hi")

        // 3. Bad joins are rejected.
        check("re-joining the same code is rejected", await throwsActionError(.alreadyLinked) {
            try await b.actions.joinPager(code.display) })
        check("an invalid code is rejected", await throwsActionError(.invalidCode) {
            try await b.actions.joinPager("nope-nope") })
        check("a valid-but-unknown code is rejected", await throwsActionError(.nodeNotFound) {
            try await b.actions.joinPager(ShareCode.generate().display) })

        // 4. Live conversation: B replies, A receives it through real SSE.
        a.connect(); b.connect()
        if let bLinkId = b.store.links.first?.id {
            try? await b.actions.send(text: "reply-yo", code: code, linkId: bLinkId)
        }
        check("B's reply reaches A live", await E2E.waitUntil { a.received[link.id] == "reply-yo" })

        // A single commit (popover close) propagates without a second nudge.
        let aReply = "a-reply-\(UUID().uuidString.prefix(6))"
        try? await a.actions.send(text: String(aReply), code: code, linkId: link.id)
        if let bLinkId = b.store.links.first?.id {
            check("A's single commit reaches B live", await E2E.waitUntil { b.received[bLinkId] == String(aReply) })
        } else {
            check("A's single commit reaches B live", false)
        }

        // 5. Unlink removes local state only; the node stays for the friend.
        a.disconnect()
        a.store.remove(id: link.id)
        check("unlinking removes the local link", a.store.links.isEmpty)
        let nodeStillThere = ((try? await transport.get(pathId: PagerCrypto(code: code).pathId)) ?? nil) != nil
        check("unlink leaves the server node intact", nodeStillThere)

        // 6. Debug-report composition (captured, not sent to Mail).
        check("debug report composes", b.sendDebugReport(includeMessages: false) && b.mail.last != nil)
        check("debug report targets the support email", b.mail.last?.recipient == PagerConfig.supportEmail)
        check("debug report omits codes by default", b.mail.last?.body.contains(code.display) == false)
        b.sendDebugReport(includeMessages: true)
        check("opting in includes the pager code", b.mail.last?.body.contains(code.display) == true)

        await E2E.deleteNode(dbURL: dbURL, pathId: PagerCrypto(code: code).pathId)
        a.cleanup(); b.cleanup()
    }

    static func throwsActionError(_ expected: PagerActionError, _ block: () async throws -> Void) async -> Bool {
        do { try await block(); return false }
        catch { return (error as? PagerActionError) == expected }
    }
}
