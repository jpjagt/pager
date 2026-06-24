# Commit-on-close + draft/menu-bar/remote decoupling — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the bug where popover edits only sync on the *next* open, and decouple the private draft from the menu bar and from incoming remote messages.

**Architecture:** Extract the editing logic out of the AppKit-bound `LinkViewModel` into a pure `EditorSession` in `PagerCore` (driven by a tiny `TextCommitter` seam over `SyncEngine`). `LinkViewModel` becomes a thin `ObservableObject` wrapper. Commit is driven by the real popover-close event via `NSPopoverDelegate.popoverDidClose`, not by SwiftUI `.onDisappear`. Remote messages flow to the menu bar (unchanged) but never touch a live draft.

**Tech Stack:** Swift, SwiftPM, AppKit/SwiftUI/Combine, XCTest. Spec: `docs/superpowers/specs/2026-06-25-pager-commit-on-close-design.md`.

---

## File structure

- **Create** `Sources/PagerCore/Models/EditorSession.swift` — the pure editing logic (`TextCommitter` protocol + `EditorSession` class).
- **Modify** `Sources/PagerCore/Sync/SyncEngine.swift` — conform `SyncEngine` to `TextCommitter` (no behavior change).
- **Modify** `Sources/Pager/UI/LinkViewModel.swift` — becomes a thin wrapper over `EditorSession`; drop the remote→draft subscription and `suppressNextEdit`.
- **Modify** `Sources/Pager/App/StatusItemController.swift` — become `NSPopoverDelegate`; add `onClose`; fire it from `popoverDidClose`.
- **Modify** `Sources/Pager/App/AppDelegate.swift` — wire `controller.onClose` to the current model's `commit()`.
- **Modify** `Sources/Pager/UI/PopoverView.swift` — remove `.onDisappear { model.commit() }`.
- **Create** `Tests/PagerCoreTests/EditorSessionTests.swift` — unit tests for `EditorSession`.
- **Modify** `Sources/E2E/main.swift` — add the `EditorSession` live scenario.
- **Modify** `Sources/E2E/Flows.swift` — add a Device-level commit-on-close assertion.

---

## Task 1: `EditorSession` + `TextCommitter` in PagerCore (TDD)

**Files:**
- Create: `Sources/PagerCore/Models/EditorSession.swift`
- Modify: `Sources/PagerCore/Sync/SyncEngine.swift` (conform to `TextCommitter`)
- Test: `Tests/PagerCoreTests/EditorSessionTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PagerCoreTests/EditorSessionTests.swift`:

```swift
import XCTest
@testable import PagerCore

/// Captures committed text instead of touching the network.
final class StubCommitter: TextCommitter {
    private(set) var committed: [String] = []
    func commitText(_ text: String) { committed.append(text) }
}

@MainActor
final class EditorSessionTests: XCTestCase {
    var store: LinkStore!
    var committer: StubCommitter!
    var link: PagerLink!
    var session: EditorSession!
    private var suiteName = ""

    override func setUp() {
        suiteName = "editorsession-\(UUID().uuidString)"
        store = LinkStore(defaults: UserDefaults(suiteName: suiteName)!)
        committer = StubCommitter()
        link = store.add(code: ShareCode(entropy: "ABCDEFGHJKMNPQ"))
        store.updateCachedText(id: link.id, text: "hello", writtenAt: 1)
        session = EditorSession(linkId: link.id, store: store, committer: committer,
                                now: { 1_000 })
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func testStartsFromCachedText() {
        XCTAssertEqual(session.text, "hello")
    }

    func testEditDoesNotPropagate() {
        session.edit("draft in progress")
        XCTAssertEqual(session.text, "draft in progress")
        XCTAssertTrue(committer.committed.isEmpty, "edit must not commit")
        XCTAssertEqual(store.links.first?.cachedText, "hello", "edit must not touch the cache/menu bar")
    }

    func testCommitSendsAndUpdatesCache() {
        session.edit("new message")
        session.commit()
        XCTAssertEqual(committer.committed, ["new message"])
        XCTAssertEqual(store.links.first?.cachedText, "new message")
    }

    func testCommitWithoutEditIsNoOp() {
        session.commit()
        XCTAssertTrue(committer.committed.isEmpty)
        XCTAssertEqual(store.links.first?.cachedText, "hello")
    }

    func testRemoteValueDoesNotClobberLiveDraft() {
        session.edit("my draft")
        // Remote message lands in the cache (as engine.onText would do).
        store.updateCachedText(id: link.id, text: "their message", writtenAt: 2)
        XCTAssertEqual(session.text, "my draft", "remote must not overwrite the draft")
        XCTAssertEqual(session.currentRemoteText, "their message")
    }

    func testCharCapEnforced() {
        session.edit(String(repeating: "x", count: 600))
        XCTAssertEqual(session.text.count, 500)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EditorSessionTests`
Expected: FAIL — `cannot find 'EditorSession' in scope` / `cannot find type 'TextCommitter'`.

- [ ] **Step 3: Create `EditorSession.swift`**

Create `Sources/PagerCore/Models/EditorSession.swift`:

```swift
import Foundation

/// The commit seam. `SyncEngine` is the real implementation; tests/e2e inject a
/// stub. Keeps `EditorSession` free of any network/engine internals.
@MainActor
public protocol TextCommitter: AnyObject {
    func commitText(_ text: String)
}

/// The pure editing logic behind the popover, extracted from `LinkViewModel` so
/// it can be driven headlessly (unit tests + e2e). No AppKit.
///
/// Model: the draft is private. `edit` mutates only the draft — never the store
/// or the committer. `commit` is the single point that pushes (on popover
/// close). Remote values land in the store/menu bar independently and never
/// overwrite a live draft.
@MainActor
public final class EditorSession {
    public private(set) var text: String
    public private(set) var detectedURLs: [TextUtil.URLMatch]

    public static let maxLength = 500

    private let linkId: UUID
    private let store: LinkStore
    private let committer: TextCommitter
    private let now: () -> Int64
    private var dirty = false

    public init(linkId: UUID, store: LinkStore, committer: TextCommitter,
                now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.linkId = linkId
        self.store = store
        self.committer = committer
        self.now = now
        let cached = store.links.first(where: { $0.id == linkId })?.cachedText ?? ""
        self.text = cached
        self.detectedURLs = TextUtil.detectURLs(in: cached)
    }

    /// The current shared/remote value (what the menu bar shows). Read-only here
    /// — the draft is never replaced from it while editing.
    public var currentRemoteText: String {
        store.links.first(where: { $0.id == linkId })?.cachedText ?? ""
    }

    /// Updates the private draft only: char cap, URL detection, mark dirty.
    /// Does not write to the store or commit.
    public func edit(_ newText: String) {
        text = newText.count > Self.maxLength ? String(newText.prefix(Self.maxLength)) : newText
        detectedURLs = TextUtil.detectURLs(in: text)
        dirty = true
    }

    /// The single commit point (popover close). Pushes the draft via the
    /// committer and writes it to the cache so the menu bar reflects the just-
    /// sent message (own writes are echo-suppressed, so onText won't do it).
    public func commit() {
        guard dirty else { return }
        dirty = false
        committer.commitText(text)
        store.updateCachedText(id: linkId, text: text, writtenAt: now())
    }
}
```

- [ ] **Step 4: Conform `SyncEngine` to `TextCommitter`**

`SyncEngine` already has `public func commitText(_ text: String)`. In `Sources/PagerCore/Sync/SyncEngine.swift`, change the class declaration line:

```swift
public final class SyncEngine {
```

to:

```swift
public final class SyncEngine: TextCommitter {
```

(No other change — the method signature already matches the protocol.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter EditorSessionTests`
Expected: PASS (6 tests).

- [ ] **Step 6: Run the full suite to confirm nothing regressed**

Run: `swift test`
Expected: PASS (all existing + new).

- [ ] **Step 7: Commit**

```bash
git add Sources/PagerCore/Models/EditorSession.swift Sources/PagerCore/Sync/SyncEngine.swift Tests/PagerCoreTests/EditorSessionTests.swift
git commit -m "feat: extract EditorSession (private draft, commit-on-close) into PagerCore

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Rewrite `LinkViewModel` as a thin wrapper over `EditorSession`

**Files:**
- Modify: `Sources/Pager/UI/LinkViewModel.swift` (full rewrite)

This is AppKit/Combine-bound (not unit-tested per the project's view boundary). Verified by build + Task 5 manual check.

- [ ] **Step 1: Replace the file contents**

Replace `Sources/Pager/UI/LinkViewModel.swift` with:

```swift
import SwiftUI
import Combine
import PagerCore

/// Thin SwiftUI bridge over `EditorSession`. Holds the private draft, mirrors
/// the offline hint, and forwards edits/commit. Remote updates reach the menu
/// bar through the store/engine path, not through this view model — a live
/// draft is never overwritten.
@MainActor
final class LinkViewModel: ObservableObject {
    @Published var text: String
    @Published var showOfflineHint = false
    @Published var detectedURLs: [TextUtil.URLMatch]

    let linkId: UUID
    private let session: EditorSession
    private let engine: SyncEngine?
    private var hintTask: Task<Void, Never>?

    var onOpenSettings: (() -> Void)?
    var onClose: (() -> Void)?

    init(link: PagerLink, store: LinkStore, engine: SyncEngine?) {
        self.linkId = link.id
        self.engine = engine
        // No engine (e.g. transport unavailable): commit is a no-op sink.
        let committer: TextCommitter = engine ?? NoopCommitter()
        self.session = EditorSession(linkId: link.id, store: store, committer: committer)
        self.text = session.text
        self.detectedURLs = session.detectedURLs

        engine?.onState = { [weak self] state in
            Task { @MainActor in self?.stateChanged(state) }
        }
        if let engine { stateChanged(engine.state) }
    }

    /// Called from the view's onChange. Keeps `detectedURLs`/cap in sync with
    /// the session after it has processed the edit.
    func textEdited() {
        session.edit(text)
        if text != session.text { text = session.text } // reflect the char cap
        detectedURLs = session.detectedURLs
    }

    /// Pushes the draft. Called from the popover-close event (AppDelegate wires
    /// this to StatusItemController.popoverDidClose).
    func commit() { session.commit() }

    /// Offline hint with a 2 s grace period so routine reconnects don't flash it.
    private func stateChanged(_ state: SyncEngine.State) {
        hintTask?.cancel()
        if state == .connected {
            showOfflineHint = false
        } else {
            hintTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                self?.showOfflineHint = true
            }
        }
    }
}

/// Used when there is no engine: edits are held locally, commit goes nowhere.
@MainActor
private final class NoopCommitter: TextCommitter {
    func commitText(_ text: String) {}
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds (warnings OK). If `PopoverView` still references removed members, that is fixed in Task 4 — build `PagerCore` alone to confirm this file is self-consistent: `swift build --target PagerCore`.

- [ ] **Step 3: Commit**

```bash
git add Sources/Pager/UI/LinkViewModel.swift
git commit -m "refactor: LinkViewModel becomes a thin wrapper over EditorSession

Drops the remote-to-draft subscription and suppressNextEdit; a live draft
is no longer clobbered by incoming remote messages.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `StatusItemController` drives commit via `popoverDidClose`

**Files:**
- Modify: `Sources/Pager/App/StatusItemController.swift`

- [ ] **Step 1: Add the `onClose` callback property**

In `Sources/Pager/App/StatusItemController.swift`, after the existing
`var makePopoverContent: (() -> NSViewController)?` line, add:

```swift
    /// Fired when the popover actually closes (chevron, Enter, or click-away).
    /// AppDelegate wires this to the current editor's commit().
    var onClose: (() -> Void)?
```

- [ ] **Step 2: Register the controller as the popover's delegate**

In `init(linkId:)`, immediately after `super.init()`, add:

```swift
        popover.delegate = self
```

- [ ] **Step 3: Conform to `NSPopoverDelegate` and implement `popoverDidClose`**

Change the class declaration from:

```swift
final class StatusItemController: NSObject {
```

to:

```swift
final class StatusItemController: NSObject, NSPopoverDelegate {
```

Then add this method inside the class (e.g. just below `closePopover()`):

```swift
    func popoverDidClose(_ notification: Notification) {
        onClose?()
    }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: builds (PopoverView fix is Task 4; if it errors only on PopoverView, proceed).

- [ ] **Step 5: Commit**

```bash
git add Sources/Pager/App/StatusItemController.swift
git commit -m "feat: StatusItemController fires onClose from popoverDidClose

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Wire `AppDelegate` + remove `.onDisappear` commit

**Files:**
- Modify: `Sources/Pager/App/AppDelegate.swift:126-134` (the `popoverContent(for:)` method)
- Modify: `Sources/Pager/UI/PopoverView.swift:69`

- [ ] **Step 1: Wire the controller's onClose to the current model's commit**

In `Sources/Pager/App/AppDelegate.swift`, replace the `popoverContent(for:)` method body so it sets `controller.onClose` to the freshly-built model's `commit`. Replace:

```swift
    func popoverContent(for linkId: UUID) -> NSViewController {
        guard let link = store.links.first(where: { $0.id == linkId }) else {
            return NSViewController()
        }
        let model = LinkViewModel(link: link, store: store, engine: engines[linkId])
        model.onClose = { [weak self] in self?.controllers[linkId]?.closePopover() }
        model.onOpenSettings = { [weak self] in self?.showSettings() }
        return NSHostingController(rootView: PopoverView(model: model, updates: updateController))
    }
```

with:

```swift
    func popoverContent(for linkId: UUID) -> NSViewController {
        guard let link = store.links.first(where: { $0.id == linkId }) else {
            return NSViewController()
        }
        let model = LinkViewModel(link: link, store: store, engine: engines[linkId])
        model.onClose = { [weak self] in self?.controllers[linkId]?.closePopover() }
        model.onOpenSettings = { [weak self] in self?.showSettings() }
        // Commit the draft when the popover actually closes (any dismissal path).
        controllers[linkId]?.onClose = { [weak model] in model?.commit() }
        return NSHostingController(rootView: PopoverView(model: model, updates: updateController))
    }
```

- [ ] **Step 2: Remove the `.onDisappear` commit from `PopoverView`**

In `Sources/Pager/UI/PopoverView.swift`, delete this line (line 69):

```swift
        .onDisappear { model.commit() } // fires on both close paths: button and click-away
```

- [ ] **Step 3: Build the whole app**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 4: Run the full test suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Pager/App/AppDelegate.swift Sources/Pager/UI/PopoverView.swift
git commit -m "fix: commit popover edits on real close, not SwiftUI onDisappear

The NSPopover never nils its contentViewController on close and had no
delegate, so .onDisappear only fired on the next open. Drive commit from
NSPopoverDelegate.popoverDidClose instead.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: e2e — `EditorSession` live scenario (the regression guard)

**Files:**
- Modify: `Sources/E2E/main.swift` (insert a new numbered scenario before the
  reconnect scenario at step 4, around line 80)

- [ ] **Step 1: Add the EditorSession scenario**

In `Sources/E2E/main.swift`, find the LWW scenario (ends near line 78 with the
`check("LWW newer write wins on both ends", ...)` call). Immediately after it,
insert:

```swift
        // 3b. EditorSession model: a draft stays private until commit; a remote
        //     message updates the menu bar (cache) but never clobbers the draft.
        //     This is the headless analogue of the popover open/type/close flow
        //     and guards the commit-on-close bug.
        let aStore = LinkStore(defaults: UserDefaults(suiteName: "e2e-editor-\(UUID().uuidString)")!)
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
        UserDefaults().removePersistentDomain(forName: aStore.suiteNameForCleanup)
```

- [ ] **Step 2: Expose the suite name for cleanup**

The snippet above calls `aStore.suiteNameForCleanup`, which does not exist.
Instead of adding API to `LinkStore`, change the two lines that create/clean the
store to hold the suite name in a local. Replace:

```swift
        let aStore = LinkStore(defaults: UserDefaults(suiteName: "e2e-editor-\(UUID().uuidString)")!)
```

with:

```swift
        let aSuite = "e2e-editor-\(UUID().uuidString)"
        let aStore = LinkStore(defaults: UserDefaults(suiteName: aSuite)!)
```

and replace:

```swift
        UserDefaults().removePersistentDomain(forName: aStore.suiteNameForCleanup)
```

with:

```swift
        UserDefaults().removePersistentDomain(forName: aSuite)
```

- [ ] **Step 3: Run e2e**

Run: `swift run e2e`
Expected: exit 0, all checks green, including the new
`commit-on-close propagates the draft to B` and `remote does not clobber A's draft`.

- [ ] **Step 4: Commit**

```bash
git add Sources/E2E/main.swift
git commit -m "test(e2e): EditorSession scenario guards commit-on-close + draft isolation

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: e2e — Device-level commit-on-close assertion

**Files:**
- Modify: `Sources/E2E/Flows.swift:97-103` (after the "B's reply reaches A live"
  check, before the unlink scenario)

- [ ] **Step 1: Add the assertion**

In `Sources/E2E/Flows.swift`, the live-conversation block (step 4) ends with:

```swift
        check("B's reply reaches A live", await E2E.waitUntil { a.received[link.id] == "reply-yo" })
```

Immediately after that line, insert:

```swift
        // A single commit (popover close) propagates without a second nudge.
        let aReply = "a-reply-\(UUID().uuidString.prefix(6))"
        try? await a.actions.send(text: String(aReply), code: code, linkId: link.id)
        check("A's single commit reaches B live", await E2E.waitUntil { b.received[link.id] == String(aReply) })
```

- [ ] **Step 2: Run e2e**

Run: `swift run e2e`
Expected: exit 0, including `A's single commit reaches B live`.

- [ ] **Step 3: Commit**

```bash
git add Sources/E2E/Flows.swift
git commit -m "test(e2e): assert a single commit propagates A to B without a re-nudge

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Manual verification (the GUI last mile)

**Files:** none (manual).

- [ ] **Step 1: Build and run the app**

Run: `swift build && swift run Pager` (or `make bundle && open dist/Pager.app`).

- [ ] **Step 2: Verify commit-on-close for every dismissal path**

With a second linked device (or watch the server / a second run):
- Open a pager, type "msg-chevron", close with the up-chevron → other device updates within ~1s.
- Open, type "msg-enter", press Enter → other device updates within ~1s.
- Open, type "msg-clickaway", click outside the popover → other device updates within ~1s.

Expected: all three propagate immediately on close (no reopen needed).

- [ ] **Step 3: Verify draft isolation from remote**

- Open a pager and start typing a draft (do not close).
- From the other device, change the text.
- Expected: the **menu bar** updates to the other device's text, while the open
  popover keeps your draft untouched. On close, your draft commits (LWW decides
  the final shared value by timestamp).

- [ ] **Step 4: Verify the menu bar is not live-echoing keystrokes**

- Open a pager and type. Expected: the menu-bar title does **not** change while
  typing; it updates only on close (your commit) or on a remote message.

---

## Self-review notes

- **Spec coverage:** commit-on-close via `popoverDidClose` (Tasks 3–4); private
  draft / no live menu-bar echo (Task 1 `edit`, Task 2 wrapper, Task 7 step 4);
  remote→menu-bar but not→draft (Task 1 + removal of subscription in Task 2 +
  e2e Task 5); commit writes cache because echo-suppressed (Task 1 `commit` +
  test `testCommitSendsAndUpdatesCache`); `EditorSession` in PagerCore + e2e
  scenario (Tasks 1, 5); Device-level assertion (Task 6); manual click-away
  verification (Task 7).
- **Type consistency:** `EditorSession(linkId:store:committer:now:)`,
  `TextCommitter.commitText(_:)`, `edit(_:)`, `commit()`, `text`,
  `currentRemoteText`, `detectedURLs` used identically across Tasks 1, 2, 5.
  `LinkViewModel(link:store:engine:)` and `onClose`/`commit()` match Task 4's
  wiring.
- **No placeholders:** every code/edit step shows full content; the one forward
  reference (`suiteNameForCleanup`) is resolved within Task 5 step 2.
```
