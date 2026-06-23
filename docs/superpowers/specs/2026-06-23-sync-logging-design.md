# Sync Logging & Debug Report — Design Spec

*2026-06-23 — approved via brainstorming session*

## Motivation

A real sync bug surfaced during testing: a friend's edit ("2" in a
count-to-ten exchange) never reached the server, while the other device's
value sat in Firebase as the latest write. The decrypted node confirmed the
**upload**, not download, was at fault — almost certainly the
`SyncEngine.apply(remote:)` stale-pending discard (a local offline edit
dropped on reconnect because its `writtenAt` was not newer than the remote),
a failed PUT, or device clock skew.

None of these are diagnosable after the fact today: the app keeps no record of
its sync decisions. This spec adds a **durable, privacy-preserving sync log**
and a one-tap **"email a debug report"** flow so a non-technical user can send
their logs to the app developer.

## Privacy model

The log contains only what the **server already sees** — ciphertext, path
ids, device ids, timestamps, and connection decisions. It **never** contains
plaintext message text, the share code, or the derived key.

Because log entries store the base64 `ct`, anyone holding the share code can
decrypt them with the repo's `decode-log` tool. The debug-email flow therefore
puts the share code(s) behind an explicit, default-off opt-in checkbox: with it
off, the developer receives an undecryptable log; with it on, the user has
consented to the developer reading the affected messages.

## Components

### 1. `SyncLog` (PagerCore)

Foundation-only (no AppKit), so it lives in `PagerCore`, stays unit-testable,
and is reused verbatim by the decode tool's schema.

- A **sink protocol** the engine writes to:
  ```swift
  public protocol SyncLogSink: Sendable {
      func log(_ event: SyncLogEvent)
  }
  ```
- **`SyncLogEvent`** — a `Codable` struct serialized as one JSON object per
  line (JSONL). Fields are optional and event-specific; common fields:
  `t` (ISO-8601 ms wall-clock string), `ev` (event name), `link` (first 8 hex
  of pathId), `nick` (link nickname).
- A **file-backed implementation**, `FileSyncLog`, that appends one line per
  event to a single file and is safe to call from the main actor. On append,
  if the file exceeds **2 MB** it is **truncated and restarted** (no rotated
  copy kept).
- A **no-op implementation** used as the default, so existing tests and any
  `SyncEngine` constructed without a sink are unaffected.

`SyncEngine.init` gains a `log: SyncLogSink = NoopSyncLog()` parameter. The
engine emits events at the points enumerated below. No behavior changes — the
engine only *observes* its own decisions.

### 2. Event taxonomy

Instrumented at the exact decision points in `SyncEngine` (line numbers as of
this writing):

| `ev` | Site | Fields beyond common |
| --- | --- | --- |
| `edit.set` | `setText` | `writtenAt`, `len`, `ct` |
| `edit.commit` | `commitText` | `writtenAt`, `len`, `ct` |
| `flush.put_ok` | `flushPending` success | `writtenAt`, `ct` |
| `flush.put_fail` | `flushPending` catch | `writtenAt`, `error` |
| `apply.pending_wins` | `apply` L151 | `pending_wa`, `remote_wa` |
| `apply.discard_pending` ⚠️ | `apply` L154 | `pending_wa`, `remote_wa`, `remote_by` |
| `apply.echo` | `apply` L157 | `writtenAt` |
| `apply.reject_stale` | `apply` L165 | `remote_wa`, `last_wa` |
| `apply.accept` | `apply` L168 | `writtenAt`, `len`, `ct` |
| `apply.undecryptable` | `apply` L168 (nil) | `ct` |
| `state` | state `didSet` | `state` (connected/reconnecting/offline) |
| `stream.open` | first `put` after connect | — |
| `stream.drop` | runLoop catch | `error` |
| `reconnect` | `reconnectNow` | reason (`wake`/`path`) |

`keep-alive` events are **not** logged (too noisy). `apply.discard_pending`
is the marquee line — it captures both `writtenAt`s and the remote device id,
which alone distinguishes offline-discard from clock skew.

The `ev` strings, field names, and `SyncLogEvent` shape are the stable
contract between the engine and `decode-log`.

### 3. `decode-log` executable (new SwiftPM target)

A small executable target depending on `PagerCore`, so it reuses `ShareCode`
and `PagerCrypto` — zero risk of derivation drift versus the app.

```sh
swift run decode-log --code 5NDQ-WHM1-85X3-FWPQ ~/Library/Logs/Pager/pager-logs.jsonl
```

For each JSONL line it parses the `SyncLogEvent`, and if a `ct` field is
present, decrypts it with the supplied code and reprints the line with a
decoded `text:"…"` appended. Lines whose `ct` does not decrypt under the given
code (a different link) are annotated `[other link]`. Accepts multiple
`--code` flags so a multi-link log can be fully decoded in one pass.

This generalizes the throwaway `peek.swift` used during diagnosis.

### 4. App wiring (`Pager`)

- `AppDelegate` constructs one shared `FileSyncLog` at
  `~/Library/Logs/Pager/pager-logs.jsonl` and passes it into every
  `SyncEngine` it creates.
- `PagerConfig` gains:
  ```swift
  public static let supportEmail = "yo@july.dev"
  ```

### 5. "Email a debug report" CTA (`SettingsView`)

Replaces any reveal-in-Finder / copy-diagnostics idea. A single button with a
short, lowercase explanation:

> something not syncing? send a debug report to pager's app developer. it
> attaches a technical log of recent sync activity. your messages stay
> encrypted in the log — they can only be read if you opt in below.

- **Checkbox (default off):** `include the messages that were sent and
  received on your pagers`. When on, the email body lists every link's share
  **code**.
- **Mechanism:** `NSSharingService(named: .composeEmail)` with `recipients =
  [PagerConfig.supportEmail]`, a subject, the body template below, and the
  `pager-logs.jsonl` file as an attachment item. The button is disabled with a
  "no mail account configured" hint when `canPerform(withItems:)` is false.

**Body template** (greeting lowercase; debug block normal capitalization):

```
hi! pager isn't behaving. here's what's going wrong:

[please share details about what's going wrong here]

--- Extra debug information (please don't remove) ---
Pager version: 1.0.0 (build 1)
macOS version:  14.5.0
Links (1):
  • "BFF"  path 2aaf9352  device 2B0E4AB1  state connected  lastWrittenAt 1781368776670
```

When the checkbox is on, append (for **all** links):

```
Pager codes (you chose to include these so the app developer can read your messages):
  • "BFF": 5NDQ-WHM1-85X3-FWPQ
```

Version/build come from `Info.plist`
(`CFBundleShortVersionString` / `CFBundleVersion`); macOS from
`ProcessInfo.operatingSystemVersion`; per-link rows from `LinkStore` plus each
`SyncEngine`'s current `state` and last `writtenAt`. The full process
environment dump is intentionally omitted as noise.

## Testing

- **`FileSyncLog`:** append produces one valid JSON line per event; crossing
  2 MB truncates and restarts the file.
- **`SyncEngine` events:** drive the existing `URLProtocol`/stub-transport
  integration tests and assert the expected `ev` sequence — in particular that
  the stale-offline-edit scenario emits `apply.discard_pending` with the
  correct `pending_wa` / `remote_wa`.
- **`decode-log`:** round-trip — encrypt a value with a known code, write a log
  line, decode it, assert the recovered plaintext; assert `[other link]` for a
  ct under a different code.
- **Manual:** trigger the Settings button, confirm Mail opens pre-filled with
  the attachment, and that the codes block appears only when the box is checked.

## Out of scope

Log levels/filtering, remote log upload, in-app log viewer, rotated history
beyond the single 2 MB file, logging anything outside the sync path.
