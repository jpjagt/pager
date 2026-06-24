import Foundation
import PagerCore

// End-to-end test of the real sync path: two SyncEngine "devices" talking
// through the live FirebaseClient (SSE + PUT), the layer the unit tests stub.
//
//   swift run e2e
//
// Isolation: each run uses a freshly generated share code → a unique,
// unguessable Firebase path that cannot collide with real pagers. It touches
// no UserDefaults and no log file, and DELETEs its node when done. Override the
// backend with PAGER_DATABASE_URL (e.g. a local emulator).

@MainActor
enum E2E {
    static func run() async -> Int32 {
        let urlString = ProcessInfo.processInfo.environment["PAGER_DATABASE_URL"]
            ?? PagerConfig.databaseURLString
        guard let dbURL = URL(string: urlString), !urlString.contains("CHANGE-ME") else {
            print("no database URL configured"); return 2
        }

        let transport = FirebaseClient(baseURL: dbURL)
        let code = ShareCode.generate()
        let crypto = PagerCrypto(code: code)
        let pathId = crypto.pathId
        print("• backend \(dbURL.host ?? "?")")
        print("• fresh code \(code.display)  path \(pathId)\n")

        // Real FileSyncLog per device, to isolated temp files (NOT the app's
        // ~/Library/Logs/Pager log) so we exercise the actual on-disk writer.
        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-logs-\(UUID().uuidString)")
        let logAURL = logDir.appendingPathComponent("a.jsonl")
        let logBURL = logDir.appendingPathComponent("b.jsonl")
        let logA = FileSyncLog(url: logAURL)
        let logB = FileSyncLog(url: logBURL)

        // A device's "view" is what it would show: its own last commit, or the
        // last value pushed to it. onText fires only for REMOTE changes (a
        // device's own writes are echo-suppressed), so commits update the view
        // manually — mirroring how the real editor holds locally-typed text.
        var aView: String?
        var bView: String?
        let a = SyncEngine(transport: transport, crypto: crypto, pathId: pathId, deviceId: "E2E-A", log: logA)
        a.onText = { t, _ in aView = t }
        let b = SyncEngine(transport: transport, crypto: crypto, pathId: pathId, deviceId: "E2E-B", log: logB)
        b.onText = { t, _ in bView = t }
        func commitA(_ t: String) { aView = t; a.commitText(t) }
        func commitB(_ t: String) { bView = t; b.commitText(t) }

        a.start(); b.start()

        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "  ✓ \(name)" : "  ✗ \(name)")
            if !ok { failures += 1 }
        }

        check("both engines connect", await waitUntil { a.state == .connected && b.state == .connected })

        // 1. A → B
        let m1 = "hello-\(nonce())"
        commitA(m1)
        check("A→B propagation", await waitUntil { bView == m1 })

        // 2. B → A
        let m2 = "hiback-\(nonce())"
        commitB(m2)
        check("B→A propagation", await waitUntil { aView == m2 })

        // 3. LWW: a newer write wins on both ends.
        let older = "older-\(nonce())"
        commitA(older)
        _ = await waitUntil { bView == older }
        let newer = "newer-\(nonce())"
        commitB(newer)
        check("LWW newer write wins on both ends", await waitUntil { aView == newer && bView == newer })

        // 3b. EditorSession model: a draft stays private until commit; a remote
        //     message updates the menu bar (cache) but never clobbers the draft.
        //     This is the headless analogue of the popover open/type/close flow
        //     and guards the commit-on-close bug.
        let aSuite = "e2e-editor-\(UUID().uuidString)"
        let aStore = LinkStore(defaults: UserDefaults(suiteName: aSuite)!)
        let aLink = aStore.add(code: code)
        aStore.updateCachedText(id: aLink.id, text: bView ?? "", writtenAt: 1)
        let session = EditorSession(linkId: aLink.id, store: aStore, committer: a)

        let draft = "draft-\(nonce())"
        session.edit(draft)
        // Draft is private: server, B's view, and A's cache are all untouched.
        let serverBefore = try? await transport.get(pathId: pathId)
        check("draft does not reach the server",
              serverBefore.flatMap { crypto.decrypt($0.ct) } != draft)
        check("draft does not reach B", bView != draft)
        check("draft does not touch A's menu-bar cache",
              aStore.links.first?.cachedText != draft)

        // While A holds the draft, B sends — it updates A's menu-bar cache but
        // not the draft.
        let interrupt = "interrupt-\(nonce())"
        commitB(interrupt)
        check("B's message reaches the server", await serverHas(interrupt, transport: transport, crypto: crypto, pathId: pathId))
        aStore.updateCachedText(id: aLink.id, text: interrupt, writtenAt: 2) // engine.onText analogue
        check("remote updates A's menu bar", aStore.links.first?.cachedText == interrupt)
        check("remote does not clobber A's draft", session.text == draft)

        // Closing the popover commits: the draft now propagates to B.
        session.commit()
        check("commit-on-close propagates the draft to B", await waitUntil { bView == draft })
        check("commit updates A's own menu-bar cache", aStore.links.first?.cachedText == draft)
        UserDefaults().removePersistentDomain(forName: aSuite)

        // 4. Reconnect: B misses a write while its stream is down, then catches
        //    up from SSE state replay on reconnect.
        b.stop(); bView = nil
        let away = "whileaway-\(nonce())"
        commitA(away)
        check("write lands on server while B is offline", await serverHas(away, transport: transport, crypto: crypto, pathId: pathId))
        b.start()
        check("B catches up after reconnect (SSE replay)", await waitUntil(15) { bView == away })

        a.stop(); b.stop()

        // 5. Logging: the real FileSyncLog wrote valid JSONL to disk, the
        //    sender logged its own edits + PUTs, the receiver logged accepts,
        //    and the logged ciphertext decrypts back to the sent text.
        let aEvents = await waitForEvents(logAURL) { evs in
            evs.contains { $0.ev == "edit.commit" } && evs.contains { $0.ev == "flush.put_ok" }
        }
        let bEvents = await waitForEvents(logBURL) { evs in
            evs.contains { $0.ev == "apply.accept" }
        }
        check("log files are valid JSONL on disk", !aEvents.isEmpty && !bEvents.isEmpty)
        check("sender logs its own edit + PUT", aEvents.contains { $0.ev == "edit.commit" }
            && aEvents.contains { $0.ev == "flush.put_ok" })
        check("receiver logs accepted remote writes", bEvents.contains { $0.ev == "apply.accept" })
        check("every line is tagged with the link", (aEvents + bEvents).allSatisfy { $0.link == String(pathId.prefix(8)) })
        let aSent = aEvents.filter { $0.ev == "edit.commit" }.compactMap { $0.ct.flatMap(crypto.decrypt) }
        let bGot = bEvents.filter { $0.ev == "apply.accept" }.compactMap { $0.ct.flatMap(crypto.decrypt) }
        check("logged ciphertext decrypts to sent text (sender)", aSent.contains(m1))
        check("logged ciphertext decrypts to received text (receiver)", bGot.contains(m1))
        check("no plaintext written to the log file", logHasNoPlaintext(logAURL, sample: m1)
            && logHasNoPlaintext(logBURL, sample: m1))

        // App-level flows: two isolated "devices" through create/join/converse/
        // unlink/debug-mail (PagerActions + LinkStore + captured composer).
        print("\n  — app-level flows (two isolated devices) —")
        await Flows.run(transport: transport, dbURL: dbURL, check: check)

        await deleteNode(dbURL: dbURL, pathId: pathId)
        try? FileManager.default.removeItem(at: logDir)
        print("\n  cleaned up test node + temp logs")

        print(failures == 0
            ? "\nPASS — all scenarios green"
            : "\nFAIL — \(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }

    static func loadEvents(_ url: URL) -> [SyncLogEvent] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return s.split(separator: "\n").compactMap { try? dec.decode(SyncLogEvent.self, from: Data($0.utf8)) }
    }

    /// FileSyncLog flushes on a background queue; poll until the events arrive.
    static func waitForEvents(_ url: URL, timeout: TimeInterval = 5,
                              _ cond: ([SyncLogEvent]) -> Bool) async -> [SyncLogEvent] {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let evs = loadEvents(url)
            if cond(evs) { return evs }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return loadEvents(url)
    }

    /// The plaintext must never appear verbatim in the raw log bytes.
    static func logHasNoPlaintext(_ url: URL, sample: String) -> Bool {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return true }
        return !raw.contains(sample)
    }

    /// Polls a predicate on the main actor until true or timeout.
    static func waitUntil(_ timeout: TimeInterval = 10, _ cond: @MainActor () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return cond()
    }

    /// Confirms the server node actually decrypts to `text` (independent of the
    /// engines), so reconnect tests don't race the PUT.
    static func serverHas(_ text: String, transport: FirebaseClient, crypto: PagerCrypto,
                          pathId: String, timeout: TimeInterval = 10) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let v = try? await transport.get(pathId: pathId), crypto.decrypt(v.ct) == text {
                return true
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return false
    }

    static func deleteNode(dbURL: URL, pathId: String) async {
        var req = URLRequest(url: dbURL.appendingPathComponent("pagers/\(pathId).json"))
        req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
    }

    static func nonce() -> String {
        String(UUID().uuidString.prefix(6))
    }
}

exit(await E2E.run())
