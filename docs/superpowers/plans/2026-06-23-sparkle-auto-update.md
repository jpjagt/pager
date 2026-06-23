# Sparkle Auto-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add in-app updates via Sparkle 2 with a non-intrusive "Update now" affordance (no unsolicited modal), shipped from july.dev.

**Architecture:** Sparkle lives entirely in the `Pager` app target at the AppKit boundary (like `SharingServiceMailComposer`); `PagerCore` is untouched. A single `UpdateController` wraps Sparkle's updater, implements gentle-reminder suppression, and publishes update state to the per-link `PopoverView` and the shared `SettingsView`. Versioning and release packaging are Makefile concerns.

**Tech Stack:** SwiftPM, Sparkle 2 (SPM), AppKit/SwiftUI, `make`, `generate_keys`/`generate_appcast` (Sparkle tools), git.

## Global Constraints

- macOS 13+ (`.macOS(.v13)`), pure SwiftPM, no Xcode project.
- **Ad-hoc codesigning only** (`codesign -s -`); no notarization / Developer ID in this plan.
- **`PagerCore` must not import Sparkle or AppKit.** All Sparkle code is in the `Pager` target.
- Sparkle is the package's only third-party dependency; keep it that way.
- Feed URL: `https://july.dev/pager/appcast.xml`. Download base: `https://july.dev/pager/`.
- Release artifacts land in `/Users/jeroen/code/jpjagt/july.dev/public/pager/`.

---

### Task 1: Git-derived versioning in the Makefile

**Files:**
- Modify: `Makefile` (the `bundle` target, lines 9-17, plus new vars at top)

**Interfaces:**
- Produces: a bundled `Info.plist` whose `CFBundleShortVersionString` = `git describe` and `CFBundleVersion` = commit count. Source `packaging/Info.plist` stays a template.

- [ ] **Step 1: Add version vars near the top of `Makefile`** (after `DIST = dist`)

```make
VERSION := $(shell git describe --tags --always 2>/dev/null || echo 0.0.0)
BUILD := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)
```

- [ ] **Step 2: Stamp the bundled plist in the `bundle` target**

Add these two lines immediately after the `cp packaging/Info.plist …/Contents/Info.plist` line:

```make
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(DIST)/$(APP).app/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD)" $(DIST)/$(APP).app/Contents/Info.plist
```

- [ ] **Step 3: Verify the stamp**

Run: `make bundle && /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" dist/Pager.app/Contents/Info.plist && /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dist/Pager.app/Contents/Info.plist`
Expected: build number equals `git rev-list --count HEAD`; short-version equals `git describe --tags --always`. Neither is `1.0.0`/`1`.

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "build: derive bundle version from git in make bundle"
```

---

### Task 2: Add Sparkle dependency, EdDSA keys, and Info.plist feed

**Files:**
- Modify: `Package.swift`
- Modify: `packaging/Info.plist`
- (one-time, local) generate EdDSA keypair

**Interfaces:**
- Produces: `import Sparkle` available to the `Pager` target; `SUFeedURL` + `SUPublicEDKey` in `Info.plist`.

- [ ] **Step 1: Add the Sparkle package dependency in `Package.swift`**

Add a `dependencies:` array to the `Package(...)` and the product to the `Pager` target:

```swift
let package = Package(
    name: "Pager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "decode-log", targets: ["DecodeLog"]),
        .executable(name: "e2e", targets: ["E2E"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "PagerCore", path: "Sources/PagerCore"),
        .executableTarget(
            name: "Pager",
            dependencies: ["PagerCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Pager"),
        .executableTarget(name: "DecodeLog", dependencies: ["PagerCore"], path: "Sources/DecodeLog"),
        .executableTarget(name: "E2E", dependencies: ["PagerCore"], path: "Sources/E2E"),
        .testTarget(name: "PagerCoreTests", dependencies: ["PagerCore"], path: "Tests/PagerCoreTests"),
    ]
)
```

- [ ] **Step 2: Resolve and locate Sparkle's tools**

Run: `swift build 2>&1 | tail -5 && find .build/artifacts -path '*/Sparkle/bin' -type d`
Expected: build succeeds; the `find` prints a path like `.build/artifacts/sparkle/Sparkle/bin` containing `generate_keys`, `sign_update`, `generate_appcast`.

- [ ] **Step 3: Generate the EdDSA keypair (one-time, local)**

Run (substitute the path from Step 2): `.build/artifacts/sparkle/Sparkle/bin/generate_keys`
Expected: prints a public key (a base64 string) and stores the private key in your login Keychain. **Copy the printed public key.**

Then back it up somewhere safe and **do not commit it**:
Run: `.build/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/pager-sparkle-private-key-backup.txt`

- [ ] **Step 4: Add `SUFeedURL` and `SUPublicEDKey` to `packaging/Info.plist`**

Insert before the closing `</dict>` (replace `PASTE_PUBLIC_KEY` with the key from Step 3):

```xml
    <key>SUFeedURL</key>
    <string>https://july.dev/pager/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>PASTE_PUBLIC_KEY</string>
```

- [ ] **Step 5: Verify the build still compiles with Sparkle linked**

Run: `swift build`
Expected: PASS (Sparkle resolves and links; no code uses it yet).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved packaging/Info.plist
git commit -m "feat: add Sparkle dependency, EdDSA public key, and appcast feed URL"
```

---

### Task 3: `UpdateController` (Sparkle seam + gentle reminders)

**Files:**
- Create: `Sources/Pager/App/UpdateController.swift`
- Modify: `Sources/Pager/App/AppDelegate.swift` (add a stored instance, ~line 17)

**Interfaces:**
- Produces: `UpdateController: NSObject, ObservableObject` with `@Published private(set) var updateAvailable: Bool`, `@Published private(set) var availableVersion: String?`, `var automaticallyChecksForUpdates: Bool { get set }`, `func checkForUpdates()`, `func installUpdate()`. `AppDelegate.updateController` holds the single instance.

- [ ] **Step 1: Create `Sources/Pager/App/UpdateController.swift`**

```swift
import AppKit
import Sparkle

/// Thin shell over Sparkle's updater — the only code that touches Sparkle.
/// Owns the single updater instance, suppresses Sparkle's modal alert for
/// background-found updates (gentle reminders), and publishes update state to
/// the UI. Sparkle invokes its user-driver delegate on the main thread, and
/// AppDelegate constructs this on the main thread, so @Published mutations are
/// main-thread safe without extra hops.
final class UpdateController: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    /// True once a *background* check has found an update (manual checks keep
    /// Sparkle's standard UI and do not set this).
    @Published private(set) var updateAvailable = false
    @Published private(set) var availableVersion: String?

    private var updaterController: SPUStandardUpdaterController!

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Manual "Check for Updates…" — shows Sparkle's standard UI.
    func checkForUpdates() { updaterController.updater.checkForUpdates() }

    /// User tapped our "Update now" affordance. Re-presents the pending
    /// background-found update through Sparkle's standard flow (confirm →
    /// download → verify → install → relaunch). Same call as a manual check;
    /// Sparkle resurfaces the already-found update.
    func installUpdate() { updaterController.updater.checkForUpdates() }

    // MARK: SPUStandardUserDriverDelegate — gentle reminders

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false // we surface our own non-modal indicator instead of Sparkle's alert
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState) {
        guard !state.userInitiated else { return } // manual checks keep standard UI
        updateAvailable = true
        availableVersion = update.displayVersionString
    }
}
```

- [ ] **Step 2: Hold a single instance in `AppDelegate`**

In `Sources/Pager/App/AppDelegate.swift`, add after the `mailComposer` property (line 17):

```swift
    let updateController = UpdateController()
```

- [ ] **Step 3: Verify it builds**

Run: `swift build`
Expected: PASS. (If the compiler complains about `SPUStandardUserDriverDelegate` conformance isolation, mark the delegate methods `nonisolated` — but as written, with `UpdateController` not `@MainActor`, it should compile.)

- [ ] **Step 4: Commit**

```bash
git add Sources/Pager/App/UpdateController.swift Sources/Pager/App/AppDelegate.swift
git commit -m "feat: UpdateController wrapping Sparkle with gentle-reminder suppression"
```

---

### Task 4: Surface updates in `PopoverView` and `SettingsView`

**Files:**
- Modify: `Sources/Pager/UI/PopoverView.swift` (add `updates` observed object + the "Update now" link)
- Modify: `Sources/Pager/App/AppDelegate.swift` (`popoverContent`, line 125-133; `showSettings`, line 149-156)
- Modify: `Sources/Pager/Settings/SettingsView.swift` (add `updates` + an updates section)

**Interfaces:**
- Consumes: `UpdateController` from Task 3 (`updateAvailable`, `availableVersion`, `installUpdate()`, `checkForUpdates()`, `automaticallyChecksForUpdates`).

- [ ] **Step 1: Add the "Update now" link to `PopoverView`**

Add a second observed object and render the link only when an update is pending. Change the struct header:

```swift
struct PopoverView: View {
    @ObservedObject var model: LinkViewModel
    @ObservedObject var updates: UpdateController
    @FocusState private var focused: Bool
```

Then, inside the top `HStack`, immediately after `Spacer()` (before the close `Button`), insert:

```swift
                if updates.updateAvailable {
                    Button { updates.installUpdate() } label: {
                        Text("Update now").font(.caption).underline()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
```

- [ ] **Step 2: Pass the controller in `AppDelegate.popoverContent`**

In `popoverContent(for:)`, change the hosting line to inject `updateController`:

```swift
        return NSHostingController(rootView: PopoverView(model: model, updates: updateController))
```

- [ ] **Step 3: Add the updates section to `SettingsView`**

Add the observed object to the struct **immediately after `store`** (line 6) — the synthesized initializer orders parameters by declaration, so this must match the `updates`-second call site in Step 4:

```swift
    @ObservedObject var store: LinkStore
    @ObservedObject var updates: UpdateController
```

Add an `updatesSection` computed property (next to `debugSection`):

```swift
    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updates.automaticallyChecksForUpdates },
                set: { updates.automaticallyChecksForUpdates = $0 }))
            if updates.updateAvailable {
                Button("Update available — install \(updates.availableVersion ?? "")") {
                    updates.installUpdate()
                }
            } else {
                Button("Check for Updates…") { updates.checkForUpdates() }
            }
        }
    }
```

Render it in `body`, between the "Launch at login"/buttons block and the existing `Divider(); debugSection`. Add right before the existing `Divider()` on line 38:

```swift
                Divider()
                updatesSection
```

- [ ] **Step 4: Pass the controller in `AppDelegate.showSettings`**

In `showSettings()`, add `updates: updateController` to the `SettingsView(...)` initializer (first argument is fine):

```swift
        settingsWindow.show(SettingsView(
            store: store,
            updates: updateController,
            onAddPager: { [weak self] in self?.showOnboarding() },
            onEmailDebugReport: { [weak self] includeMessages in
                self?.sendDebugReport(includeMessages: includeMessages) ?? false
            }))
```

- [ ] **Step 5: Verify it builds**

Run: `swift build`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Pager/UI/PopoverView.swift Sources/Pager/Settings/SettingsView.swift Sources/Pager/App/AppDelegate.swift
git commit -m "feat: surface update state in popover (Update now) and settings"
```

---

### Task 5: Embed Sparkle.framework, add `make release`, verify end-to-end

**Files:**
- Modify: `Makefile` (`bundle` target embeds the framework; new `release` target + vars)

**Interfaces:**
- Consumes: everything above.
- Produces: `dist/Pager.app` containing `Contents/Frameworks/Sparkle.framework`; `make release` regenerating `appcast.xml` and copying both artifacts to the july.dev public dir.

- [ ] **Step 1: Add release vars near the top of `Makefile`**

```make
SITE := /Users/jeroen/code/jpjagt/july.dev/public/pager
SPARKLE_TOOLS := $(shell find .build/artifacts -path '*/Sparkle/bin' -type d 2>/dev/null | head -1)
```

- [ ] **Step 2: Embed and deep-sign Sparkle in the `bundle` target**

In the `bundle` target, replace the final `codesign --force -s - $(DIST)/$(APP).app` line with the framework-embed + ordered signing block:

```make
	mkdir -p $(DIST)/$(APP).app/Contents/Frameworks
	cp -R .build/apple/Products/Release/Sparkle.framework $(DIST)/$(APP).app/Contents/Frameworks/
	install_name_tool -add_rpath "@executable_path/../Frameworks" $(DIST)/$(APP).app/Contents/MacOS/$(APP) 2>/dev/null || true
	codesign --force --deep -s - $(DIST)/$(APP).app/Contents/Frameworks/Sparkle.framework
	codesign --force -s - $(DIST)/$(APP).app
```

- [ ] **Step 3: Verify the framework is embedded and the app launches**

Run: `make bundle && ls dist/Pager.app/Contents/Frameworks/ && codesign --verify --verbose dist/Pager.app && open dist/Pager.app`
Expected: `Sparkle.framework` listed; `codesign --verify` reports valid on disk; the menu-bar app launches (📟 or a pager item appears) without a dyld "Library not loaded: Sparkle" crash. If it crashes on missing Sparkle, the `@rpath` step failed — confirm the rpath with `otool -l dist/Pager.app/Contents/MacOS/Pager | grep -A2 LC_RPATH`.

- [ ] **Step 4: Add the `release` target** (add `release` to `.PHONY` and append the target)

```make
release: zip
	@test -n "$(SPARKLE_TOOLS)" || { echo "Sparkle tools not found — run swift build first"; exit 1; }
	$(SPARKLE_TOOLS)/generate_appcast --download-url-prefix "https://july.dev/pager/" $(DIST)/
	cp $(DIST)/$(APP).zip $(SITE)/Pager.zip
	cp $(DIST)/appcast.xml $(SITE)/appcast.xml
	@echo "→ copied Pager.zip + appcast.xml to $(SITE)"
```

(`generate_appcast` reads the EdDSA private key from your Keychain, reads the version from the app inside the zip, signs the archive, and writes `dist/appcast.xml`.)

- [ ] **Step 5: Verify the appcast generates and is signed**

Run: `make release && grep -E "sparkle:(version|edSignature)|enclosure url" dist/appcast.xml`
Expected: an `enclosure` URL of `https://july.dev/pager/Pager.zip`, a `sparkle:version` equal to the current commit count, and a non-empty `sparkle:edSignature`. Confirm the two files now exist in `$(SITE)`.

- [ ] **Step 6: End-to-end self-update (the real bar — manual)**

  1. Build N: check out a commit, `make release`, deploy the july.dev site (or serve `$(SITE)` locally and temporarily point `SUFeedURL` at it). Install build N (`open dist/Pager.app`, or copy to /Applications).
  2. Build N+1: make a trivial commit (so the commit count increments), `make release`, deploy/serve again.
  3. With build N running, trigger a background check (or click **Check for Updates…** in Settings to confirm the path), then confirm: a **background** find shows the non-modal **"Update now"** in the popover with **no** unsolicited alert; clicking it runs Sparkle's download → install → relaunch into build N+1; the menu bar comes back on the new build.
  4. Confirm `swift test` still passes (no PagerCore regressions): `swift test`.

- [ ] **Step 7: Commit**

```bash
git add Makefile
git commit -m "build: embed Sparkle.framework and add make release (appcast + publish)"
```

---

## Notes & deliberate scope trims (lean)

- **Release notes / `NOTES=`:** deferred. `generate_appcast` supports per-release HTML notes files; wiring a one-liner through is a later refinement, not needed for the update mechanism to work. The spec flagged this as minor.
- **Appcast history:** `make release` keeps only the latest `Pager.zip` in `dist/`, so the published appcast lists the latest version. Sparkle only needs the latest to offer an update; multi-version history is not required.
- **One-click (no confirm) install:** `installUpdate()` re-presents Sparkle's standard confirm-then-install prompt. This achieves the goal — no *unsolicited* popup ever interrupts the user; the prompt only appears after they tap "Update now." A fully custom no-confirm `SPUUserDriver` is possible later but is more integration than this lean pass warrants.
- **Notarization / Developer ID / Mac App Store:** out of scope (additive later, no rework — see spec).
