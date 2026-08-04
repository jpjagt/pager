# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> `CLAUDE.md` is a symlink to this file (`AGENTS.md`). Edit `AGENTS.md`.

## What this is

**Pager** — a macOS menu bar app (in the spirit of One Thing) showing a short
text that is **shared and end-to-end encrypted** across all devices linked by a
share code. Latest edit wins everywhere, instantly. No accounts, no auth, no
server-readable data — just the share code, which is both the DB address and the
encryption key. A pager can also hold an E2E-encrypted image (dropped on the
menu bar item or pasted in the popover), re-encoded to JPEG ≤ 600 KB and stored
inline in the same node (`type: "img"`).

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
make clean

# Decode a user-submitted sync log (the ct fields are E2E-encrypted; the
# share code is the key). Repeat --code for multi-link logs.
swift run decode-log --code ABCD-EFGH-JKLM-NPQR ~/Library/Logs/Pager/pager-logs.jsonl

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
instead. The remaining GUI last mile (real menu-bar item, popovers) is verified
manually.

There is no Xcode project — this is a **SwiftPM** package (`Package.swift`).
Zero third-party dependencies; AppKit/SwiftUI/CryptoKit/Network only.

### Publishing a release

After `make zip`, publish the artifact to the july.dev site so the download link works:

```sh
cp dist/Pager.zip /Users/jeroen/code/jpjagt/july.dev/public/pager/Pager.zip
```

## Architecture

Four SwiftPM targets:

- **`PagerCore`** (library) — all pure, testable logic. No AppKit. This is where the tests live and where most logic changes belong.
- **`Pager`** (executable) — the AppKit/SwiftUI shell. `@main` is `PagerApp` in `Sources/Pager/PagerApp.swift` (an `NSApplication` accessory app — menu-bar only, `LSUIElement`).
- **`DecodeLog`** (executable, `decode-log`) — CLI that decrypts a submitted sync log given the share code(s).
- **`E2E`** (executable, `e2e`) — the live integration harness against real Firebase (see Commands).

### Core logic vs. views — the testability boundary

The guiding rule: **every decision lives in `PagerCore`; the SwiftUI views and
AppKit controllers are deliberately dumb.** This is what makes the app
end-to-end testable without driving a GUI.

- **`PagerCore` holds all the logic worth testing** — crypto, sync/LWW, the
  create/join/send flows (`PagerActions`), debug-report assembly
  (`DebugReportFactory`), persistence (`LinkStore`). It has no AppKit import, so
  `swift test` and `swift run e2e` exercise it directly.
- **The views are thin shells.** `AddPagerView` gathers text and calls
  `PagerActions`, mapping `PagerActionError` → on-screen messages; `PopoverView`
  edits and calls `LinkViewModel`/`SyncEngine`; `SettingsView` renders state and
  fires callbacks. None of them make decisions worth a test — if you find
  yourself adding logic to a view, it probably belongs in `PagerCore`.
- **AppKit-touching side effects sit behind seams** so the core stays pure and
  the harness can substitute fakes: `SyncTransport` (network), `MailComposer`
  (the only thing that touches Mail/`NSSharingService`), `SyncLogSink` (disk).
  Tests/E2E inject stubs/captors; the app injects the real impls.

The payoff: the `e2e` harness reproduces "create on A → join on B → converse →
unlink → compose debug mail" by driving two `PagerActions`+`LinkStore` "devices"
headlessly. The only thing left for manual verification is pure presentation
(the menu-bar item, popover rendering) — which is why no XCUITest is needed.

### PagerCore layers

- **`Crypto/`** — `ShareCode` (16-char Crockford-base32 generate/parse/checksum) and `PagerCrypto` (HKDF-SHA256 derivation of `pathId` + AES-256-GCM key, GCM encrypt/decrypt). The share code never leaves the device; the server only ever sees `pathId` (a one-way hash) and ciphertext.
- **`Models/`** — `PagerLink` (a single shared note: code + derived path/key, local-only nickname, appearance prefs, cached text), `LinkStore` (owns all links, persists to `UserDefaults`, source of truth for UI), `PagerValue` (the wire/DB node shape: `ct`, `writtenAt`, `updatedAt`, `updatedBy`, optional `type`), `ImageDiskCache` (decrypted image bytes cached on disk, one file per link — `UserDefaults` holds only `cachedIsImage`).
- **`Images/`** — `ImageCodec` (ImageIO downscale/JPEG-encode to ≤ 600 KB), `ImageDisplayMath` (9:16-clamped display boxes), `DropPayloadClassifier` (drop/paste contents → image|text decision), `ImageURLPreviewLoader` (receiver-side lazy image-URL previews).
- **`PagerActions.swift`** — the create/join/send flows (write initial node, code validation, node-existence check, persist, surface friend's waiting message), extracted from the SwiftUI views so they're testable headlessly. `AddPagerView` is a thin shell over it. Errors surface as `PagerActionError` (`invalidCode`/`alreadyLinked`/`nodeNotFound`/`network`).
- **`Diagnostics/DebugReport.swift`** — `DebugReport` (pure email-body builder), `DebugReportFactory` (assembles one from `LinkStore` + engine states), and the `MailComposer`/`ComposedMail` seam (real `NSSharingService` impl lives in the app; tests/E2E capture the composed mail).
- **`Sync/`** — `SyncEngine` (**one instance per link**; owns subscribe/write/reconnect/LWW), `SyncTransport` (protocol abstracting Firebase REST — this is the seam tests stub via `URLProtocol`), `FirebaseClient` (the real transport: PUT writes, SSE reads), `SSEParser` (Server-Sent Events line parser), `Backoff` (exponential 1s→30s), `SyncLog` (`SyncLogSink` protocol + `FileSyncLog` JSONL writer + `SyncLogEvent`).
- **`PagerConfig.swift`** — the committed Firebase RTDB URL (not a secret; privacy comes from unguessable paths + E2E encryption) and `supportEmail`. See `docs/firebase-setup.md` for the one-time manual RTDB + `firebase/rules.json` setup.

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

- **`App/`** — `AppDelegate` (wires `LinkStore` → one `StatusItemController` + one `SyncEngine` per link; owns the shared `FileSyncLog`; gathers + composes the debug email; onboarding on first launch), `StatusItemController` (one `NSStatusItem` + `NSPopover` per link), `SharingServiceMailComposer` (the real `MailComposer`, the only debug-report code that touches AppKit), `LaunchAtLogin` (`SMAppService`), `WindowHost`.
- **`UI/`** — SwiftUI: `PopoverView` (One Thing-style borderless editor), `AddPagerView` (create/join — a thin shell over `PagerActions`), `LinkViewModel`.
- **`Settings/`** — `SettingsView` (one shared window listing all links).

### Key invariants (don't break these)

- **One `SyncEngine` and one `StatusItemController` per link.** Links cannot share a connection (paths are unrelated hashes; rules forbid parent reads).
- **Conflict resolution is last-write-wins keyed on `writtenAt`** (client time), ties broken by `updatedBy` lexicographic. `updatedAt` is server-set, debug/forensic only.
- **Echo suppression:** ignore incoming values whose `updatedBy` == this device's id.
- **Encryption lives only at the network boundary.** Cached text is stored decrypted in `UserDefaults`; menu bar is never blank on launch without network.
- **Nicknames are local-only and never synced.**
- **A pager holds text OR an image, never both.** The wire discriminator is the optional `type` field (absent ⇒ text); the code discriminator is `PagerContent`, parsed once at the sync boundary.
- **img log events carry `ct_len`, never the image ciphertext.**
- Writes apply optimistically to the menu bar immediately; PUTs debounce ~300ms. Max text length 500 chars.

## Testing approach

Two layers, matching the core-vs-views boundary above:

- **Unit (`swift test`, `Tests/PagerCoreTests/`)** — fast, offline, deterministic.
  `SyncEngine` tests inject a stub `SyncTransport` (or `URLProtocol`-based
  `FirebaseClient` tests) feeding scripted SSE bytes to assert reconnect/backoff
  and LWW; `PagerActions` and `DebugReport` tests use a stub transport + captured
  mail. When changing sync/crypto/flow logic, add tests here rather than testing
  through the AppKit shell.
- **Integration (`swift run e2e`)** — covers what the stubs can't: the real
  Firebase round-trip and the app-level flows across two isolated devices. Not
  part of `swift test` (needs network); run it before shipping a sync/flow change.

If a behavior can only be tested through a SwiftUI view or `NSStatusItem`, that's
a signal the logic should move into `PagerCore` behind a seam.
