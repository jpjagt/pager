# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> `CLAUDE.md` is a symlink to this file (`AGENTS.md`). Edit `AGENTS.md`.

## What this is

**Pager** — a macOS menu bar app (in the spirit of One Thing) showing a short
text that is **shared and end-to-end encrypted** across all devices linked by a
share code. Latest edit wins everywhere, instantly. No accounts, no auth, no
server-readable data — just the share code, which is both the DB address and the
encryption key. A pager can also hold an E2E-encrypted image (dropped on the
menu bar item or pasted in the pager window), re-encoded to JPEG ≤ 600 KB and
stored inline in the same node (`type: "img"`).

- **Design spec (read first):** `docs/superpowers/specs/2026-06-11-bff-pager-design.md` — the authoritative description of share-code format, crypto derivation, sync protocol, LWW rules, and UX flows. The implementation tracks it closely.
- **Implementation plan:** `docs/superpowers/plans/2026-06-11-pager.md`
- **User-facing copy / landing page:** `/Users/jeroen/code/jpjagt/july.dev/src/pages/pager.astro` — the website copy and install instructions. Keep `docs/install.md` and the app's onboarding wording consistent with it.

## Commands

```sh
swift build              # debug build
swift test               # run all tests
swift test --filter ShareCodeTests          # one test class/target
swift test --filter ShareCodeTests/testRoundTrip   # one test method
make build               # release, universal (arm64 + x86_64)
make bundle              # build + assemble dist/Pager.app (ad-hoc codesigned)
make zip                 # bundle + produce dist/Pager.zip
make release             # zip + appcast + copy both to july.dev (no version bump)
make release-patch       # bump vX.Y.Z, tag, then release — also -minor / -major
make clean

# Decode a user-submitted sync log (the ct fields are E2E-encrypted; the
# share code is the key). Repeat --code for multi-link logs.
swift run decode-log --code ABCD-EFGH-JKLM-NPQR ~/Library/Logs/Pager/pager-logs.jsonl

# Dev-only, headless PNG renderer for PagerUI device views — a real (never
# shown) NSWindow + NSHostingView is measured and cached to a bitmap, so
# chrome/color changes can be checked by looking at an image instead of
# running the full app. --state renders one named state (empty/long/image/
# offline/update); --case/--screen pick the palette; --pressed renders one
# key's pressed look in isolation; --sheet ignores the rest and instead
# renders a contact sheet of every case × screen color plus every named
# state, all in one PNG. Never shipped — `make bundle` does not reference it.
swift run design-preview --state long --case beige --screen red --out preview.png
swift run design-preview --sheet --out contact-sheet.png

# Live end-to-end test against real Firebase, exits non-zero on failure. Two
# layers: (1) engine/logging scenarios (SSE+PUT, LWW, reconnect, on-disk log),
# and (2) app-level flows — two isolated "devices" doing create→join→converse→
# unlink→compose-debug-mail via PagerActions + LinkStore. Fresh throwaway code
# per run, DELETEs its node + temp logs after. PAGER_DATABASE_URL overrides the
# backend (e.g. a local emulator).
swift run e2e
```

`swift test` is fully offline/deterministic (stubbed transport). The network
round-trip is covered separately by `swift run e2e`, which is intentionally not
part of the test suite. UI tests (XCUITest) are deliberately not used — this is
a pure-SwiftPM, menu-bar (`LSUIElement`) app with no Xcode project; the testable
logic is extracted into `PagerActions`/`DebugReport` and driven headlessly
instead. The remaining GUI last mile (real menu-bar item, pager windows) is
verified manually.

There is no Xcode project — this is a **SwiftPM** package (`Package.swift`).
Sparkle (auto-update) is the only third-party dependency; everything else is
AppKit/SwiftUI/CryptoKit/Network.

### Publishing a release

One command, from `main`, with a clean working tree:

```sh
make release-patch       # v0.1.1 → v0.1.2
make release-minor       # v0.1.1 → v0.2.0
make release-major       # v0.1.1 → v1.0.0
```

It computes the next version from the latest `v*` tag, creates an annotated tag,
then re-enters Make to build → zip → generate the Sparkle appcast → copy
`Pager.zip` + `appcast.xml` to `/Users/jeroen/code/jpjagt/july.dev/public/pager/`.
The site still has to be deployed separately for users to see the update.

The tag is **local only** — push it yourself (`git push origin vX.Y.Z`).

The version string comes from git, not from a file: `VERSION` is
`git describe --tags --always` and `CFBundleVersion` is the commit count. That's
why bumping and building can't happen in one Make process — Make expands
`VERSION` when it parses the Makefile, so the tag has to exist beforehand, and
`release-*` re-invokes `$(MAKE) release` after tagging.

Three guards abort before anything is tagged: releases must be cut from `main`;
uncommitted tracked changes are refused (untracked files are ignored); and an
already-tagged HEAD is refused, because two `v*` tags on one commit make
`git describe` ambiguous and the bundle would get stamped with the wrong one.
Use bare `make release` to re-publish the current tag without bumping.

## Architecture

Six SwiftPM targets:

- **`PagerCore`** (library) — all pure, testable logic. No AppKit. This is where the tests live and where most logic changes belong.
- **`PagerUI`** (library) — the skeuomorphic device views (`PagerDeviceView`, `PagerShell`, `LCDPanel`, `Banner`, key shapes, noise texture) rendered from a plain `PagerDeviceState`/`PagerDeviceActions` pair. No AppKit-shell types, no store/engine access — props in, callbacks out — which is what lets `DesignPreview` render any state from a literal.
- **`Pager`** (executable) — the AppKit/SwiftUI shell. `@main` is `PagerApp` in `Sources/Pager/PagerApp.swift` (an `NSApplication` accessory app — menu-bar only, `LSUIElement`).
- **`DecodeLog`** (executable, `decode-log`) — CLI that decrypts a submitted sync log given the share code(s).
- **`E2E`** (executable, `e2e`) — the live integration harness against real Firebase (see Commands).
- **`DesignPreview`** (executable, `design-preview`) — dev-only, headless PNG renderer for `PagerUI` device views (see Commands). Never shipped: `make bundle` only ever copies the `Pager` binary into `dist/Pager.app`.

### Core logic vs. views — the testability boundary

The guiding rule: **every decision lives in `PagerCore`; the SwiftUI views and
AppKit controllers are deliberately dumb.** This is what makes the app
end-to-end testable without driving a GUI.

- **`PagerCore` holds all the logic worth testing** — crypto, sync/LWW, the
  create/join/send flows (`PagerActions`), debug-report assembly
  (`DebugReportFactory`), persistence (`LinkStore`). It has no AppKit import, so
  `swift test` and `swift run e2e` exercise it directly.
- **The views are thin shells.** `AddPagerView` gathers text and calls
  `PagerActions`, mapping `PagerActionError` → on-screen messages; `PagerDeviceAdapter`
  maps `LinkViewModel`/`UpdateController` onto `PagerUI`'s state/actions and
  `LinkViewModel` itself is a thin bridge over `EditorSession`; `SettingsView`
  renders state and fires callbacks. None of them make decisions worth a test —
  if you find yourself adding logic to a view, it probably belongs in `PagerCore`
  (or, for pure device-chrome logic, `PagerUI`).
- **AppKit-touching side effects sit behind seams** so the core stays pure and
  the harness can substitute fakes: `SyncTransport` (network), `MailComposer`
  (the only thing that touches Mail/`NSSharingService`), `SyncLogSink` (disk).
  Tests/E2E inject stubs/captors; the app injects the real impls.

The payoff: the `e2e` harness reproduces "create on A → join on B → converse →
unlink → compose debug mail" by driving two `PagerActions`+`LinkStore` "devices"
headlessly. The only thing left for manual verification is pure presentation
(the menu-bar item, pager window rendering) — which is why no XCUITest is
needed. `design-preview` covers a good chunk of that presentation gap for the
device chrome specifically, by rendering `PagerUI` states to a PNG headlessly.

### PagerCore layers

- **`Crypto/`** — `ShareCode` (16-char Crockford-base32 generate/parse/checksum) and `PagerCrypto` (HKDF-SHA256 derivation of `pathId` + AES-256-GCM key, GCM encrypt/decrypt). The share code never leaves the device; the server only ever sees `pathId` (a one-way hash) and ciphertext.
- **`Models/`** — `PagerLink` (a single shared note: code + derived path/key, local-only nickname, `AppearancePrefs`, cached text, `windowFrame` — the persisted **visible-device** rect of its `PagerWindow`, restored on next launch), `AppearancePrefs` (`screenColor` + `caseColor`, the two independent skeuomorphic theme axes — assigned/rotated per link by `LinkStore`, no free-form hex), `LinkStore` (owns all links, persists to `UserDefaults`, source of truth for UI), `PagerValue` (the wire/DB node shape: `ct`, `writtenAt`, `updatedAt`, `updatedBy`, optional `type`), `ImageDiskCache` (decrypted image bytes cached on disk, one file per link — `UserDefaults` holds only `cachedIsImage`), `EditorSession` (the pure editing/commit state machine behind the pager window — see Key invariants).
- **`Theme/`** — `ScreenColor` (7 LCD palettes) and `CaseColor` (2 case-plastic palettes); each is a total enum resolving to a complete hex palette, so every combination renders.
- **`Window/`** — `PagerWindowPlacement`, the fallback cascade/avoid-overlap math used the first time a link's window opens (before it has a persisted `windowFrame`).
- **`Images/`** — `ImageCodec` (ImageIO downscale/JPEG-encode to ≤ 600 KB), `ImageDisplayMath` (9:16-clamped display boxes), `DropPayloadClassifier` (drop/paste contents → image|text decision), `ImageURLPreviewLoader` (receiver-side lazy image-URL previews).
- **`PagerActions.swift`** — the create/join/send flows (write initial node, code validation, node-existence check, persist, surface friend's waiting message), extracted from the SwiftUI views so they're testable headlessly. `AddPagerView` is a thin shell over it. Errors surface as `PagerActionError` (`invalidCode`/`alreadyLinked`/`nodeNotFound`/`network`).
- **`Diagnostics/DebugReport.swift`** — `DebugReport` (pure email-body builder), `DebugReportFactory` (assembles one from `LinkStore` + engine states), and the `MailComposer`/`ComposedMail` seam (real `NSSharingService` impl lives in the app; tests/E2E capture the composed mail).
- **`Sync/`** — `SyncEngine` (**one instance per link**; owns subscribe/write/reconnect/LWW), `SyncTransport` (protocol abstracting Firebase REST — this is the seam tests stub via `URLProtocol`), `FirebaseClient` (the real transport: PUT writes, SSE reads), `SSEParser` (Server-Sent Events line parser), `Backoff` (exponential 1s→30s), `SyncLog` (`SyncLogSink` protocol + `FileSyncLog` JSONL writer + `SyncLogEvent`).
- **`PagerConfig.swift`** — the committed Firebase RTDB URL (not a secret; privacy comes from unguessable paths + E2E encryption) and `supportEmail`. See `docs/firebase-setup.md` for the one-time manual RTDB + `firebase/rules.json` setup.

### PagerUI layers

- **`PagerDeviceState`/`PagerDeviceActions`** — the entire input surface of the device: a plain struct of literals in, a struct of callbacks out. No AppKit-shell/store/engine types cross this boundary, which is what lets `DesignPreview` render any state (including ones hard to reach live, like `offline` or `update`) from a literal.
- **`PagerDeviceView`** — composes the fixed vertical stack (offline banner → text → image → link banners → update banner) inside a `PagerShell` (case + keys + wordmark) wrapping an `LCDPanel` (screen).
- **`Device/`** — `PagerShell`, `LCDPanel`, `Banner` (the chrome strip used for both link and update banners), `KeyShapes`, `NoiseTexture`.

### Diagnostics (sync logging + debug email)

`SyncEngine` emits structured events to an injected `SyncLogSink` at every
`apply()` branch (`discard_pending`, `reject_stale`, `accept`, `echo`, …),
edit, flush, and state change — logging is pure observation, no behavior
change. The app wires a `FileSyncLog` writing JSONL to
`~/Library/Logs/Pager/pager-logs.jsonl` (capped at 2 MB; restarts fresh, no
rotation). **Log lines carry only ciphertext** (`ct`), never plaintext or the
share code — same trust boundary as the server. Image events log only `ct_len`
(the ciphertext length), never the image ciphertext itself. Settings → "Email a debug
report" builds a `DebugReport` via `DebugReportFactory` and hands it to a
`MailComposer` (`SharingServiceMailComposer` → `NSSharingService(.composeEmail)`
in the app; a captor in tests/E2E), attaching the log; an opt-in checkbox
additionally includes the share code(s) so the recipient can run `decode-log`.
Design: `docs/superpowers/specs/2026-06-23-sync-logging-design.md`.

### Pager (app shell) layers

- **`App/`** — `AppDelegate` (wires `LinkStore` → one `StatusItemController` + one `SyncEngine` + one `PagerWindow` (opened on demand) per link; owns the shared `FileSyncLog`; gathers + composes the debug email; onboarding on first launch), `StatusItemController` (one `NSStatusItem` per link — the menu bar half only; the pager itself lives in the window), `PagerWindow` (a borderless, floating, draggable `NSWindow` holding one pager device — replaced `NSPopover`: it does not auto-dismiss, several can be open at once, and its frame persists to `PagerLink.windowFrame`), `SharingServiceMailComposer` (the real `MailComposer`, the only debug-report code that touches AppKit), `LaunchAtLogin` (`SMAppService`), `WindowHost` (generic host used for the onboarding/settings windows), `AppActivation` (the `activate()`/`activate(ignoringOtherApps:)` OS-version split, shared by `UpdateController` and `AppDelegate`).
- **`UI/`** — `PagerDeviceAdapter` (the only place live models meet the device chrome: maps `LinkViewModel` + `UpdateController` + window focus onto `PagerUI`'s `PagerDeviceState`/`PagerDeviceActions` — holds no logic beyond that mapping), `AddPagerView` (create/join — a thin shell over `PagerActions`, stays native macOS), `LinkViewModel` (thin SwiftUI bridge over `EditorSession`).
- **`Settings/`** — `SettingsView` (one shared window listing all links; stays native macOS).

### Key invariants (don't break these)

- **One `SyncEngine` and one `StatusItemController` per link.** Links cannot share a connection (paths are unrelated hashes; rules forbid parent reads).
- **Conflict resolution is last-write-wins keyed on `writtenAt`** (client time), ties broken by `updatedBy` lexicographic. `updatedAt` is server-set, debug/forensic only.
- **Echo suppression:** ignore incoming values whose `updatedBy` == this device's id.
- **Encryption lives only at the network boundary.** Cached text is stored decrypted in `UserDefaults`; menu bar is never blank on launch without network.
- **Nicknames are local-only and never synced.**
- **A pager holds text OR an image, never both.** The wire discriminator is the optional `type` field (absent ⇒ text); the code discriminator is `PagerContent`, parsed once at the sync boundary.
- **img log events carry `ct_len`, never the image ciphertext.**
- Writes apply optimistically to the menu bar immediately; PUTs debounce ~300ms. Max text length 500 chars.
- **Committing is no longer tied to one gesture.** `EditorSession` (the pure editing state machine behind the pager window) exposes explicit `commit()` / `clear()` / `discard()` verbs, driven by the send / clear / close keys respectively (`LinkViewModel.submit()`/`clear()`/`dismiss()`): send pushes the draft and closes the window; clear empties the draft but stays open, still editing; close abandons the edit, reverting to the last cached content (whatever landed remotely mid-edit wins — consistent with LWW). Only `commit()` calls the `ContentCommitter` seam and updates the cache; `clear()`/`discard()` never push to the network.
- **Quitting commits, it does not discard.** A pager window can hold a draft for hours, so `applicationWillTerminate` commits every open session and then calls `SyncEngine.flushSynchronously()` — the debounced/async PUT would otherwise never leave the machine. Quit is not the ✕ key.

## Testing approach

Two layers, matching the core-vs-views boundary above:

- **Unit (`swift test`, `Tests/PagerCoreTests/` + `Tests/PagerUITests/`)** — fast,
  offline, deterministic. `SyncEngine` tests inject a stub `SyncTransport` (or
  `URLProtocol`-based `FirebaseClient` tests) feeding scripted SSE bytes to
  assert reconnect/backoff and LWW; `PagerActions` and `DebugReport` tests use a
  stub transport + captured mail; `PagerUITests` covers pure, deterministic
  `PagerUI` logic (e.g. `NoiseTexture`) that doesn't need a live window. When
  changing sync/crypto/flow logic, add tests here rather than testing through
  the AppKit shell.
- **Integration (`swift run e2e`)** — covers what the stubs can't: the real
  Firebase round-trip and the app-level flows across two isolated devices. Not
  part of `swift test` (needs network); run it before shipping a sync/flow change.

If a behavior can only be tested through a SwiftUI view or `NSStatusItem`, that's
a signal the logic should move into `PagerCore` behind a seam.
