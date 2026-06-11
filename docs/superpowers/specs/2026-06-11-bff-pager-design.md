# Pager — Design Spec

*(App name: **Pager**. Repo/site keep the bff-pager slug.)*

*2026-06-11 — approved via brainstorming session*

## What it is

A macOS menu bar app in the spirit of One Thing: a short text shown in the
menu bar, edited via a popover. The twist: the text is **shared** — all
devices linked by a share code show the same text, and anyone in the group
can update it. Latest edit wins everywhere, instantly. No history, no
accounts, no auth — just the share code. Text is end-to-end encrypted; the
server (and its admin) cannot read it.

A device can hold **multiple links** (e.g. one pager per BFF). Each link is
its own independent menu bar item with its own share code, text, and
appearance. Updates from friends apply **silently** — the text just changes.

## Stack

- Native Swift, macOS 13+ (Ventura), **zero third-party dependencies**.
- AppKit `NSStatusItem` + `NSPopover` shell (handles a runtime-variable
  number of status items); all popover/settings/onboarding UI is SwiftUI.
- Menu-bar-only app (`LSUIElement = true`, no dock icon).
- Backend: Firebase Realtime Database, accessed via its **plain REST API**
  (PUT for writes, Server-Sent Events for live reads) using `URLSession`.
  No Firebase SDK. Crypto via Apple CryptoKit.

## Share codes & encryption

The share code is the address **and** the key. It never reaches the server.

- **Format:** 16 Crockford-base32 characters displayed as
  `ABCD-EFGH-JKLM-NPQR`. The first 14 chars are random (70 bits entropy);
  the last 2 are a checksum (leading 10 bits of SHA-256 of the first 14),
  so typos are caught client-side at join time. Case-insensitive input;
  hyphens optional when pasting.
- **Derivation** (CryptoKit HKDF-SHA256 over the 14 entropy chars):
  - `pathId  = hex(HKDF(code, info: "bffpager:path", 16 bytes))` → DB path `/pagers/{pathId}`
  - `aesKey  = HKDF(code, info: "bffpager:key", 32 bytes)` → AES-256-GCM key
  - HKDF outputs are independent and one-way: knowing `pathId` (which the
    server sees) reveals nothing about the code or key.
- **Encryption:** AES-GCM with a fresh random 12-byte nonce per write;
  stored value is `base64(nonce ‖ ciphertext ‖ tag)`.

## Data model & sync protocol

One node per link:

```
/pagers/{pathId} = {
  ct:        "<base64 nonce+ciphertext+tag>",   // the encrypted text
  writtenAt: 1749632100123,                      // client Unix ms at edit time
  updatedAt: 1749632320123,                      // server Unix ms at update time
                                                 // (PUT sends {".sv":"timestamp"};
                                                 //  server fills it in; debug/forensic
                                                 //  only — LWW keys on writtenAt)
  updatedBy: "<random per-device UUID>"
}
```

Per link, one `SyncEngine` instance (links cannot share a connection —
paths are unrelated hashes and rules forbid parent reads; per-link engines
keep reconnect state isolated). All engines share one `URLSession`.

- **Subscribe:** SSE stream (`Accept: text/event-stream`) on
  `/pagers/{pathId}.json`. Firebase replays full state on connect, then a
  `put` event per change. Handle `keep-alive` events; ignore `patch`
  (we only ever PUT whole nodes).
- **Write:** edits apply optimistically to the menu bar immediately; PUTs
  are debounced ~300 ms while typing. Max text length 500 chars, enforced
  in the app.
- **Echo suppression:** a device ignores incoming values whose `updatedBy`
  equals its own device id (prevents cursor-fighting while typing).
- **Conflict resolution — last-write-wins by `writtenAt`:**
  - An incoming value replaces local state only if its `writtenAt` is newer
    than the local value's.
  - A pending offline edit is pushed on reconnect only if its `writtenAt`
    is newer than the remote's; otherwise it is discarded and the remote
    value shown. (Stale offline text can never clobber a friend's newer
    update; an edit genuinely typed later while offline still wins.)
  - Ties break deterministically by `updatedBy` lexicographic comparison.
  - Caveat (accepted): trusts NTP-synced device clocks; fine at
    human-timescale edits between friends.
- **Reconnect:** exponential backoff 1 s → 30 s cap on stream drop or PUT
  failure. `NWPathMonitor` (network path restored) and `NSWorkspace`
  wake-from-sleep notifications trigger an immediate reconnect, skipping
  the backoff. SSE replaying full state on connect makes reconnects
  self-healing.
- **Create flow** writes an initial encrypted empty node immediately, so
  **Join** verifies the node exists before accepting a code.
- Last known decrypted text per link is cached locally; the menu bar is
  never blank on launch without network. Encryption exists only at the
  network boundary.

## Firebase setup & rules (one-time, manual)

Owner creates a free Firebase project, enables RTDB, applies
`firebase/rules.json` from this repo, and the database URL is committed in
app config (it is not a secret; privacy = unguessable paths + E2E
encryption). Rules:

- No read/list at `/pagers` root (no enumeration).
- Read/write allowed at `/pagers/{pathId}`.
- Validate node shape: `ct` is a string ≤ 2 KB, `writtenAt` is a number,
  `updatedAt` is a number, `updatedBy` is a string ≤ 64 chars, no extra
  keys.

## App architecture

- **`LinkStore`** — owns the array of links; persists to `UserDefaults`
  (share code, nickname, appearance prefs, cached text, device id).
  Source of truth observed by UI.
- **`PagerLink`** (model) — share code + derived pathId/key, local-only
  nickname (default "Pager 1", never synced), appearance prefs
  (max width, text size, color), cached text + `writtenAt`.
- **`SyncEngine`** (one per link) — protocol logic above; exposes
  `connected / reconnecting / offline`; UI-agnostic, talks to `LinkStore`
  via callbacks.
- **`StatusItemController`** (one per link) — owns `NSStatusItem` +
  `NSPopover`. Renders text truncated to per-link max width, with per-link
  font size and color. URLs render underlined. Emoji work natively.
  Empty text renders 📟 so the item stays clickable.
- **Popover (SwiftUI)** — One Thing-style: borderless text field; typing
  updates menu bar + syncs immediately (debounced). Chevron-up button
  closes; clicking the status item again also closes. Detected links are
  clickable from the popover. `⋯` button opens the Settings window.
  Footnote **"offline, will sync when back online"** appears when the
  link's engine state ≠ `connected` for > 2 s (grace period avoids
  flicker on routine sub-second reconnects); clears on reconnect.

## UX flows

- **Onboarding (first launch):** small window with *Create a pager*
  (generates code, shows it large with copy button, "send this to your
  BFF") or *Join with code* (paste field; checksum-validated inline; node
  existence verified). Prominently offers the **Launch at Login** toggle
  (`SMAppService.mainApp` — no helper app).
- **Settings (one shared window, `⌘,`):** a list of all links — each row:
  nickname (editable), share code + copy button, max-width slider, text
  size, color picker, **Unlink** button. App-wide section below: Launch at
  Login toggle, "Add a pager…" (reopens create/join UI), Quit.
- **Unlink:** removes the status item and local state; the DB node is left
  untouched (others may still use it).

## Error handling

- **Offline / stream drop:** keep showing cached text; popover footnote as
  above; backoff reconnect + instant reconnect on wake/path-change.
- **Typo'd code:** rejected inline by checksum; valid-but-nonexistent code
  rejected by the node-existence check.
- **Undecryptable value** (corruption/tampering): ignore, keep last good
  text.
- **Failed PUT:** retried with backoff; the edit stays pending under LWW.

## Testing

- **XCTest units** (pure logic): share code generate/checksum/parse, HKDF
  derivation against fixed vectors, AES-GCM round-trip, SSE event parser
  (canned streams: initial put, keep-alive, reconnect), LWW resolution
  table, URL detection.
- **`SyncEngine` integration:** `URLProtocol` stub feeding scripted SSE
  bytes; assert reconnect/backoff and LWW behavior.
- **Manual E2E:** add the same share code as two links on one machine —
  two status items syncing with each other through real Firebase.

## Distribution (v1)

Unsigned (ad-hoc signed by Xcode — required for Apple Silicon), zipped,
downloadable from july.dev/bff-pager. First open on modern macOS requires
System Settings → Privacy & Security → "Open Anyway"; `docs/install.md`
holds a 3-step walkthrough to adapt for the site. Notarization is a later
step and changes nothing in the app.

## Repo layout

```
Pager.xcodeproj
Sources/
  App/        # app delegate, status item controllers, launch at login
  Models/     # PagerLink, LinkStore
  Sync/       # SyncEngine, SSE parser, LWW
  Crypto/     # share code gen/parse/checksum, HKDF, AES-GCM
  UI/         # popover, onboarding
  Settings/   # settings window
Tests/
firebase/rules.json
docs/firebase-setup.md
docs/install.md
docs/superpowers/specs/   # this spec
```

## Out of scope (v1)

Notarization, iOS/other platforms, message history, multiple texts per
link, read receipts/presence, notifications or visual cues on update,
rotating/revoking share codes.
