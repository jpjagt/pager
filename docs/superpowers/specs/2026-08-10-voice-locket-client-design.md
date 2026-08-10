# Voice Locket Client — Design

**Date:** 2026-08-10
**Status:** approved design, pre-implementation
**Upstream contracts:** `../voice-locket/protocol/PROTOCOL.md` (wire contract, v1) and
`../voice-locket/voice-pendant-spec.md` (product spec). Where this document and the
protocol disagree, the protocol wins; fix whichever is wrong and bump both.

---

## 1. What this is

A full voice-locket **peer** inside the Pager macOS app. The Mac joins a circle as a
real member: it records, sends, receives, plays, chase-plays, and emits receipts. It
also serves as the **reference client** the pendant spec asks for (spec §3.3) — every
protocol and buffering bug gets found here, cheaply, before firmware exists. The
server is assumed implemented.

**No new windows, no skeuomorphic chrome.** The entire device is a menu bar item (an
LED in a ring) plus one global keyboard shortcut per circle. Hold the shortcut to
record; tap it to play. This is the pendant's own interaction grammar (spec §1.1),
mapped onto a keyboard.

**Attention model: silent.** State changes appear only in the menu bar icon. No
sounds, no Notification Center, no badges, no blinking. Consequence, accepted: the
user rarely notices a live transmission in time to chase-play it; most listening is
archive-play. Chase-play still works whenever the user taps while a transmission is
open.

**Trust-model boundary, stated in the UI.** Pager links are E2E-encrypted; voice
circles are not (the server processes plaintext audio for its DSP stage — protocol
§10). The add-circle flow carries one line of honest copy: *voice circles are not
end-to-end encrypted; the server processes audio.* Pager's E2EE promise stays intact
by being explicitly scoped to pagers.

## 2. Targets

Two new SwiftPM targets; one existing target grows.

- **`VoiceCore`** (library) — all protocol and decision logic. No AppKit. Depends on
  `PagerCore` only for `Backoff` and the `SyncLogSink` seam. Everything testable
  lives here, mirroring the PagerCore/app-shell boundary.
- **`COpus`** (C target) — vendored libopus. Wrapped by an `OpusCodec` protocol so
  tests never need the real codec.
- **`Pager`** (app) — per circle: one `NSStatusItem`, one `VoiceEngine`, one global
  hotkey. Plus the real `AudioIO` (AVAudioEngine), the provisioning view (hosted in
  `WindowHost`, like `AddPagerView`), and a circles section in Settings.
- **No PagerUI work.** There is no device view, no window, no design-preview state.

Stack decision: **hand-rolled minimal**, in the spirit of `SSEParser`. A minimal MQTT
5 subset over `Network.framework`, URLSession for chunked HTTP, vendored libopus.
Sparkle remains the only package dependency.

## 3. VoiceCore modules

### 3.1 `Identity/` — provisioning and mTLS

- Keypair generated via SecKey, private key stored in the Keychain; it never leaves
  the machine.
- A hand-built **PKCS#10 CSR** (small ASN.1 DER encoder, ~200 lines, pure and
  testable — no OpenSSL).
- Provisioning client: `POST /v1/provision` with a pasted **claim token** (protocol
  §8). The response (certificate, CA bundle, endpoints, circle config) persists via
  `CircleStore`; the certificate is stored as a `SecIdentity` for both TLS stacks.
- Open dependency: the provisioning service must issue claim tokens outside the
  USB-serial factory flow. Protocol §10 already lists this as open; the Mac client is
  its first consumer.

### 3.2 `Mqtt/` — minimal MQTT 5 client

- **`MqttPacketCodec`** — pure encode/decode for the subset the protocol needs:
  CONNECT/CONNACK (with `session present`), SUBSCRIBE/SUBACK, PUBLISH QoS 1 +
  PUBACK, PINGREQ/PINGRESP, DISCONNECT. Unknown packet types and properties are
  ignored, per the protocol's must-ignore stance. Roughly 600–900 lines including
  the session actor; tested with scripted bytes exactly like `SSEParser`.
- **`MqttSession`** — an actor over `NWConnection`: mTLS with the `SecIdentity`,
  TLS 1.3 with session resumption, persistent session (long expiry), keepalive,
  reconnect via the shared `Backoff`. Subscribes to `v1/dev/{device_id}/dl`,
  publishes to `…/up`.
- **CONNACK `session present == false`** → the engine runs the catch-up fetch
  (§3.5) before trusting the queue. Same rule as a pendant returning from months
  off (protocol §5.1).

### 3.3 `Wire/` — stream format and control messages

- **`TxnStreamCodec`** — the §6 binary format: 8-byte `VLK1` header, frame records
  (`seq`, `len`, payload), end-of-message record (`len == 0`). Pure, ~100 lines.
  Rejects unknown magic/version; discards records with `seq` below the next
  expected (sloppy-resume overlap must never double-play a frame).
- **Control messages** — `tx.start` / `tx.end` / `tx.abort` / `receipt.patch` /
  `client.stats` as Codable types that **preserve unknown keys** (receipts
  round-trip keys this client does not understand, per protocol §7.2). All handlers
  are idempotent on `txn_id`.

### 3.4 `Playout/` — the §1.2 state machine

A pure type: frames in, clock ticks in, "emit N ms of decoded audio" out.

- States `IDLE → BUFFERING → PLAYING → COMPLETE`, with `PAUSED` on underrun while
  the transmission is still open. Silent pause, rebuffer to `N_resume`, resume. No
  time-stretch, no concealment, no inserted silence.
- Buffer depth = frame count × `frame_ms` — no decoding needed to measure.
- `BUFFERING` exits on `buffer ≥ N_start` **or** end-of-message, whichever first.
- `N_start` and `N_resume` are parameters. Desktop defaults: **500 ms / 250 ms**
  (wired network; the pendant's 2000 ms is a cellular number). Tunable via config.
- Archive play is the same machine fed from disk — the buffer fills faster than
  realtime and never underruns.

This module and its tests are a deliverable in their own right: the pendant spec
(§3.3, §3.5) wants the playout machine proven against artificial network conditions
before it is ported to firmware. The tests use a deterministic clock seam and
scripted frame-arrival timing: underrun/resume, EOM before threshold, mid-stream
join via `from_seq`.

### 3.5 `Engine/` and `Record/`

- **`VoiceEngine`** — one per circle (the per-link invariant, carried over). Owns
  the MQTT session, the transmission table, the **unheard queue ordered by
  `tx_index`** (never by timestamp — devices' clocks are informational only), the
  receipt state, and download orchestration. On `tx.start` it marks a live
  transmission (menu LED goes amber); download begins on demand (tap) or eagerly
  once `tx.end` arrives, whichever first. Emits `delivered_at` when a complete
  stream is on disk, `heard_at` when first playback completes. Catch-up:
  `GET /v1/transmissions?after_index=N` bootstraps a fresh device (`N=0`) and
  reconciles an expired broker session.
- **`RecordSession`** — mic PCM in → Opus frames out → chunked `POST` while
  recording, end-of-message on stop. Frames also buffer locally, so upload starts
  whenever the connection is ready — capture never waits on the network (the
  pendant's "setup hidden inside the recording", spec §1.4). Resume flow on a
  dropped upload: `GET …/status` → re-`POST` with `from_seq = next_seq`,
  re-stating the stream header. Uplink 48 kbps, 16 kHz, 60 ms frames; `txn_id` is
  128 random bits minted locally.
- After each playback, `client.stats` telemetry is sent best-effort (underruns,
  buffer depths) — this is the data that tunes `N_start` (spec §2.4.4).

### 3.6 `Store/`

- **`CircleStore`** — persisted circle config (circle id, members, endpoints,
  device id, shortcut binding, `tx_index` cursor). Parallels `LinkStore`
  (UserDefaults for small state; the Keychain holds the identity).
- **`MessageStore`** — completed transmissions on disk as raw `VLK1` streams (no
  transcoding), an unheard index, and a heard history bounded by a **disk budget**,
  not a timer — deterministic capacity, most recent always retained (the pendant's
  retention rule, spec §1.4). `saved` is a protocol-level receipt flag from day
  one; a browsing UX for saved messages is deferred, like on the pendant.

### 3.7 Seams

Same philosophy as `SyncTransport`/`MailComposer`: AppKit- and network-touching
side effects sit behind protocols, real impls in the app, fakes in tests.

| Seam | Real impl | Tests use |
|---|---|---|
| `AudioIO` (capture + playback) | AVAudioEngine, in the app | scripted PCM |
| `OpusCodec` | libopus via `COpus` | identity/fake codec |
| `VoiceTransport` (HTTP chunked up/down, catch-up, status) | URLSession + mTLS challenge | stub with scripted bodies/timing |
| MQTT byte transport | `NWConnection` | scripted packet bytes |
| Clock | real | deterministic ticks |

**Invariant #1 of the pendant spec is enforced here:** the one owner of `AudioIO`
never allows capture and playback simultaneously. Hold-to-record while playing
stops playback first. No echo cancellation exists anywhere.

## 4. UX

### 4.1 The menu bar item is the whole device

One status item per circle: an **LED dot inside a thin ring**, with a transparent
gap between them. Drawn as a dynamic `NSImage` (redrawn for light/dark menu bar).
The ring is neutral and adapts to appearance; the LED color is the state. Steady
colors only — nothing blinks.

| State | LED |
|---|---|
| idle | off — faint gray |
| unheard messages | green |
| live incoming transmission (chase-play available) | amber |
| recording | red, plus elapsed time as status-item text: `● 0:12` |
| playing | white/bright |
| offline / error | LED off, ring dimmed |

If circles ever need telling apart beyond position, the **ring** takes a per-circle
tint so state colors stay universal. v1 ships neutral rings.

### 4.2 One shortcut per circle — hold to record, tap to play

Default **⌘⌥R** for the first circle; each circle's shortcut is configurable in
Settings via a key-capture field.

| Gesture | Action |
|---|---|
| Tap (released < ~300 ms) | Play the unheard queue, oldest first, with a short separator sound between messages (inside an already-running playback — not an attention cue, so it does not violate the silent model); chase-play if a transmission is live |
| Tap during playback | Stop |
| Hold (past ~300 ms) | Record; release stops and sends |

- Implemented with Carbon `RegisterEventHotKey`, which delivers both pressed and
  released events, works globally, and needs **no accessibility permission**.
  Repeat pressed events while held are ignored.
- **Mic capture starts at the hold threshold, not at key-down** — otherwise every
  tap-to-play would flash macOS's orange mic-in-use indicator. The ~300 ms of
  deferred capture is covered by press-then-speak timing.
- There is no forgotten-hot-mic risk and no duration cap: recording is physically
  held, exactly like the pendant's button.

### 4.3 Status item click → menu

The same verbs for mouse users, plus what a hotkey can't do:
"Play unheard (n)" / "Stop", "Record message" (click again to send), **"Discard
recording"** while recording (the only cancel path — a global Esc hotkey would
steal Esc from every app), circle name and members, the shortcut hint, and
"Unlink…".

### 4.4 Add flow and Settings

"Add voice locket…" beside the pager create/join entry points: paste a claim token
(+ server host if not baked into `VoiceConfig`), the client provisions, the LED
appears in the menu bar. The flow carries the E2EE-scoping line (§1). Settings
lists circles with their shortcut bindings and an unlink action. Native macOS UI
throughout, like `AddPagerView`/`SettingsView`.

### 4.5 Quit during recording

Quitting **sends, it does not discard** — release-equivalent: stop capture, write
the end-of-message record, and flush the upload synchronously. Same rule as the
pagers' "quitting commits".

## 5. Errors and edge cases

- **Upload connection drop** → resume flow (§3.5). A server crash mid-upload
  recovers identically, since `next_seq` reflects durable storage.
- **Mac sleep/wake** → MQTT reconnect with backoff; on `session present == false`,
  catch-up fetch. TLS session resumption keeps reconnects cheap.
- **`tx.abort` / `410 Gone`** → drop the queue entry silently; an aborted
  transmission keeps its `tx_index` (gaps are legal).
- **Mic permission denied** → recording verbs disabled in the menu with a hint;
  hold gesture does nothing. Playback still works.
- **Duplicate MQTT deliveries** (QoS 1) → all handlers idempotent on `txn_id`.
- **Wall-clock** for receipt timestamps comes from any HTTPS `Date` header —
  informational only, never used for ordering.

## 6. Testing

Two layers, matching the existing boundary:

- **Unit (`swift test`, `Tests/VoiceCoreTests/`)** — offline, deterministic:
  `MqttPacketCodec` and `TxnStreamCodec` round-trips and malformed input, the ASN.1
  CSR encoder against known-good DER, the playout machine under scripted arrival
  timing (underrun, EOM-before-threshold, mid-stream join, resume overlap
  discard), `VoiceEngine` with stub transports (LWW-free but idempotency-heavy:
  duplicate `tx.start`, replayed PUBLISH, catch-up reconciliation), receipt
  unknown-key preservation.
- **Integration (`swift run e2e`, new voice stage)** — two headless VoiceCore
  "devices" against the real server (endpoint via env var): provision → record →
  chase-play on the other side → receipts → resume-after-cut → catch-up after a
  dropped session. Artificial jitter/latency injection lives in the transport
  stubs — this harness is the §3.3 reference-client job, and it stays useful as
  the pendant firmware's test bench.
- **Manual last mile** — menu bar rendering, real audio in/out, hotkey feel.

## 7. Explicitly out of scope (v1)

- Saved-message browsing UX (the `saved` receipt flag ships; UI later).
- Sounds/notifications of any kind.
- Per-circle ring tints (design ready, not shipped).
- E2EE for voice (blocked on the server DSP A/B — protocol §10).
- Power management (§1.4 of the pendant spec) — meaningless on a Mac.

## 8. Open questions

- Claim-token issuance flow for non-factory clients (shared with protocol §10).
- Whether `N_start = 500 ms` is right on desktop — `client.stats` will tell.
- Multiple circles per Mac is assumed to work (one status item + engine + identity
  per circle, each its own provisioned device). The *pendant* multi-circle
  question (protocol §10) is untouched by this.
