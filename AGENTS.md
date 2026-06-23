# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> `CLAUDE.md` is a symlink to this file (`AGENTS.md`). Edit `AGENTS.md`.

## What this is

**Pager** — a macOS menu bar app (in the spirit of One Thing) showing a short
text that is **shared and end-to-end encrypted** across all devices linked by a
share code. Latest edit wins everywhere, instantly. No accounts, no auth, no
server-readable data — just the share code, which is both the DB address and the
encryption key.

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
```

There is no Xcode project — this is a **SwiftPM** package (`Package.swift`).
Zero third-party dependencies; AppKit/SwiftUI/CryptoKit/Network only.

### Publishing a release

After `make zip`, publish the artifact to the july.dev site so the download link works:

```sh
cp dist/Pager.zip /Users/jeroen/code/jpjagt/july.dev/public/pager/Pager.zip
```

## Architecture

Two SwiftPM targets:

- **`PagerCore`** (library) — all pure, testable logic. No AppKit. This is where the tests live and where most logic changes belong.
- **`Pager`** (executable) — the AppKit/SwiftUI shell. `@main` is `PagerApp` in `Sources/Pager/PagerApp.swift` (an `NSApplication` accessory app — menu-bar only, `LSUIElement`).

### PagerCore layers

- **`Crypto/`** — `ShareCode` (16-char Crockford-base32 generate/parse/checksum) and `PagerCrypto` (HKDF-SHA256 derivation of `pathId` + AES-256-GCM key, GCM encrypt/decrypt). The share code never leaves the device; the server only ever sees `pathId` (a one-way hash) and ciphertext.
- **`Models/`** — `PagerLink` (a single shared note: code + derived path/key, local-only nickname, appearance prefs, cached text), `LinkStore` (owns all links, persists to `UserDefaults`, source of truth for UI), `PagerValue` (the wire/DB node shape: `ct`, `writtenAt`, `updatedAt`, `updatedBy`).
- **`Sync/`** — `SyncEngine` (**one instance per link**; owns subscribe/write/reconnect/LWW), `SyncTransport` (protocol abstracting Firebase REST — this is the seam tests stub via `URLProtocol`), `FirebaseClient` (the real transport: PUT writes, SSE reads), `SSEParser` (Server-Sent Events line parser), `Backoff` (exponential 1s→30s), `SyncLog` (`SyncLogSink` protocol + `FileSyncLog` JSONL writer + `SyncLogEvent`).
- **`PagerConfig.swift`** — the committed Firebase RTDB URL (not a secret; privacy comes from unguessable paths + E2E encryption) and `supportEmail`. See `docs/firebase-setup.md` for the one-time manual RTDB + `firebase/rules.json` setup.

### Diagnostics (sync logging + debug email)

`SyncEngine` emits structured events to an injected `SyncLogSink` at every
`apply()` branch (`discard_pending`, `reject_stale`, `accept`, `echo`, …),
edit, flush, and state change — logging is pure observation, no behavior
change. The app wires a `FileSyncLog` writing JSONL to
`~/Library/Logs/Pager/pager-logs.jsonl` (capped at 2 MB; restarts fresh, no
rotation). **Log lines carry only ciphertext** (`ct`), never plaintext or the
share code — same trust boundary as the server. Settings → "Email a debug
report" (`DebugReport` + `NSSharingService(.composeEmail)`) attaches the log;
an opt-in checkbox additionally includes the share code(s) so the recipient
can run `decode-log`. Design: `docs/superpowers/specs/2026-06-23-sync-logging-design.md`.

### Pager (app shell) layers

- **`App/`** — `AppDelegate` (wires `LinkStore` → one `StatusItemController` + one `SyncEngine` per link; owns the shared `FileSyncLog`; composes the debug email; onboarding on first launch), `StatusItemController` (one `NSStatusItem` + `NSPopover` per link), `DebugReport` (pure email-body builder), `LaunchAtLogin` (`SMAppService`), `WindowHost`.
- **`UI/`** — SwiftUI: `PopoverView` (One Thing-style borderless editor), `AddPagerView` (create/join), `LinkViewModel`.
- **`Settings/`** — `SettingsView` (one shared window listing all links).

### Key invariants (don't break these)

- **One `SyncEngine` and one `StatusItemController` per link.** Links cannot share a connection (paths are unrelated hashes; rules forbid parent reads).
- **Conflict resolution is last-write-wins keyed on `writtenAt`** (client time), ties broken by `updatedBy` lexicographic. `updatedAt` is server-set, debug/forensic only.
- **Echo suppression:** ignore incoming values whose `updatedBy` == this device's id.
- **Encryption lives only at the network boundary.** Cached text is stored decrypted in `UserDefaults`; menu bar is never blank on launch without network.
- **Nicknames are local-only and never synced.**
- Writes apply optimistically to the menu bar immediately; PUTs debounce ~300ms. Max text length 500 chars.

## Testing approach

`PagerCore` is designed for unit testing without a network or UI. `SyncEngine`
integration tests inject a stub `SyncTransport` (or `URLProtocol`-based
`FirebaseClient` tests) feeding scripted SSE bytes to assert reconnect/backoff
and LWW behavior. When changing sync/crypto logic, add/adjust tests in
`Tests/PagerCoreTests/` rather than testing through the AppKit shell.
