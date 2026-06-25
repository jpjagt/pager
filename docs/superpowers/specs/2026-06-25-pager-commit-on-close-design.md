# Commit-on-close + draft/menu-bar/remote decoupling

**Date:** 2026-06-25
**Status:** Approved, ready for implementation plan

## Problem

Two related defects in the popover editing flow.

### 1. Edits don't sync when the popover closes (the reported bug)

Changing the text and closing the popover does not push to the server. The
message only goes out when the popover is **reopened** later. Both close paths
(the up-chevron / Enter, and click-away) behave identically.

**Root cause.** `commit()` — the immediate encrypted PUT of edited text — is
wired to SwiftUI's `.onDisappear` on `PopoverView`:

```swift
.onDisappear { model.commit() } // PopoverView.swift
```

But the app's `NSPopover`:

- has **no `NSPopoverDelegate`**, and
- **never nils its `contentViewController` on close** — it only *replaces* it on
  the next open (`StatusItemController.togglePopover`).

So when the popover is dismissed, the SwiftUI content view is not removed from
any hierarchy; it sits in a hidden, dismissed popover. `.onDisappear` therefore
does not fire at close. It fires later, when the next open swaps in a fresh
content view controller and tears down the old one. That is why the push happens
"when I reopen," and why both close paths behave identically (both go through
`performClose`, neither replaces the content VC).

**Evidence.** The on-disk sync log for the reported repro
(`~/Library/Logs/Pager/pager-logs.jsonl`) contained exactly one `edit.commit`
for the session, timestamped at the **reopen** moment, immediately followed by
`flush.put_ok`. The close itself produced no `edit.commit`. The send path works;
its trigger is wrong.

The debounced `setText` path is not involved here — while typing, edits only
call `store.updateCachedText` locally; the network push relies entirely on
`commit()`. A missed `commit()` means nothing reaches the server until the next
open.

### 2. Editing can bury a message you never saw (the conversation hazard)

Pager is a conversation over a **single shared line** (last-write-wins). Today,
while the popover is open:

- typing optimistically overwrites the **menu bar** and `cachedText`, and
- an incoming **remote** message overwrites the **open draft** (via the
  `store.$links` → `self.text` subscription in `LinkViewModel`).

The second behavior is the real hazard: the other person sends a message, and
you — mid-edit, never having seen theirs — commit over it. Their message is gone
from the shared line and you never saw it.

## Model (agreed)

Pager stays a **single-line status**, not a chat. The only sin is a *blind
overwrite* of something the other person never let you see. The fix decouples
the three things that are currently tangled — live typing, menu-bar display, and
remote updates:

- **Menu bar = remote/shared truth.** It shows the latest committed/shared
  value. It updates when a remote message arrives (even while the popover is
  open) and when you commit your own edit. It does **not** reflect your
  in-progress typing.
- **Popover = private draft.** Typing changes nothing outside the popover: not
  the menu bar, not `cachedText`, not the server.
- **Close = the single commit point.** On close, the draft is committed
  (encrypted PUT) immediately. No settle delay.

This satisfies "see theirs while you draft yours": their message appears in the
menu bar behind/above the open popover, so you can glance up, see it, and decide
what to commit. No modal interruption, no draft clobbering. LWW on the server
still arbitrates near-simultaneous commits, unchanged.

## Components

### `EditorSession` (new, in `PagerCore`)

The testable heart of the editing flow. Pure logic, **no AppKit import**, so the
unit tests and the `e2e` harness can drive it directly (mirroring the existing
`PagerActions` extraction). Owns:

- State: `text` (the draft), `dirty`, `detectedURLs`, and the 500-char cap.
- `edit(_:)` — updates the draft only: apply the char cap, recompute
  `detectedURLs`, mark `dirty`. **No** store or engine writes.
- `commit()` — if `dirty`: call `engine.commitText(text)` **and**
  `store.updateCachedText(...)`, then clear `dirty`. If not `dirty`, a no-op.
  The `store.updateCachedText` is required, not redundant: a device's own
  writes are echo-suppressed (`updatedBy == deviceId`), so `engine.onText`
  never fires for them — without the explicit cache write the menu bar would
  not reflect the message you just sent.
- `currentRemoteText` — a read-only accessor onto the link's current shared
  value, so a wrapper can show remote truth. `EditorSession` **never** mutates
  `text` from a remote value while a draft is live.

Dependencies: a `SyncEngine`-shaped commit seam and `LinkStore`. A small
protocol may be introduced for the engine seam if needed so the harness/tests
can inject, consistent with how `PagerActions` injects `SyncTransport`.

### `LinkViewModel` (Pager target)

Becomes a thin `ObservableObject` wrapper over `EditorSession`: it republishes
`text` / `detectedURLs` / `showOfflineHint` for SwiftUI and forwards
`textEdited` → `edit` and `commit` → `commit`. It **removes**:

- the `store.$links` → `self.text` subscription (the source of draft clobbering),
  and
- the `suppressNextEdit` dance, which only existed to paper over that
  subscription.

Remote-update awareness while open comes through the menu bar, not the draft.

### `StatusItemController`

Becomes the popover's `NSPopoverDelegate` and implements `popoverDidClose`,
which invokes a new `onClose` callback. The chevron and Enter paths already call
`model.onClose?()` → `closePopover()` → `performClose`, so every dismissal path
(including transient click-away) funnels through `popoverDidClose` → one commit.

### `AppDelegate`

Wires the controller's `onClose` to the current link's `EditorSession.commit()`
(the editor session lives as long as the popover's content view model). The
remote-text → menu-bar path (`engine.onText` → `store.updateCachedText`) is
unchanged.

### `PopoverView`

Remove `.onDisappear { model.commit() }`. Commit is now driven by the real
close event.

## What this deliberately does not change

- One `SyncEngine` and one `StatusItemController` per link.
- LWW keyed on `writtenAt`, ties broken by `updatedBy`.
- Echo suppression (`updatedBy == deviceId`).
- The encryption boundary (cached text stored decrypted; ciphertext only at the
  network/log boundary).
- Nicknames local-only.
- The debounced `setText` path (still present, still unused by the popover,
  harmless).

## Testing

### Unit (`swift test`, `Tests/PagerCoreTests/`)

`EditorSession` is pure `PagerCore`, so it is tested offline/deterministically
with a stub engine seam and an in-memory `LinkStore`:

- `edit(_:)` does not propagate (no store write, no engine commit).
- `commit()` sends via the engine **and** updates `cachedText`.
- a remote value does not clobber a live draft.
- closing without edits (`dirty == false`) is a no-op.
- the 500-char cap holds.

### Integration (`swift run e2e`)

Two additions against real Firebase:

1. **`EditorSession` scenario — the regression guard.** With two real engines:
   - A's `EditorSession.edit("draft")` → assert the server node, B's view, and
     A's `cachedText` are all **unchanged** (the draft is private).
   - A's `EditorSession.commit()` → assert B receives it live. This is the exact
     behavior that was broken: commit-on-close must actually send.
   - While A holds a draft, B commits a message → assert A's `cachedText` (menu
     bar) updates but A's `EditorSession.text` draft is **untouched**.

   This works because `EditorSession` lives in `PagerCore`, which the `E2E`
   target imports. The harness already models a "device's view" as the value it
   would display (`aView`/`bView`), with `onText` firing only for remote
   changes — exactly the menu-bar/draft split this design formalizes.

2. **Device-level assertion (`Flows.swift`).** After the existing conversation,
   a draft → commit → "B sees it within ~1s" check, reinforcing that a single
   commit propagates without a second nudge.

## Residual manual verification

That `popoverDidClose` fires for **all** dismissal paths — including transient
click-away — is the one true GUI seam and is verified manually (close via
chevron, via Enter, via click-away; confirm the other machine updates within
~1s each time; confirm a remote message arriving while the popover is open
updates the menu bar without disturbing the draft).
