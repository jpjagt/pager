# Skeuomorphic Reskin — Design Spec

*2026-08-05 — approved via brainstorming session*

## Motivation

Pager currently renders as a plain SwiftUI popover: a `TextField` on the system
material background. It reads as a generic utility, not as the object it is
named after.

This spec reskins the app so each pager looks like a **real physical pager** —
specifically a Motorola Memo Classic: a molded plastic case with a recessed,
backlit LCD and a rocker of hard-edged keys. Because a user can hold several
pagers at once, the device is **themed per link**: each friend gets their own
LCD color, so a pager is identifiable at a glance without reading it.

The reskin also changes the window UX. The transient `NSPopover` is replaced by
a draggable, always-on-top window, in the spirit of One Thing. That is not
cosmetic — it changes the commit model, because the window no longer closes the
moment you look away.

## Non-goals

Deliberately out of scope, to keep this to a single implementation plan:

- **Pixel/dot-matrix font and inline clickable links.** Both require replacing
  `TextField` with an `NSTextView` bridge; they are the same surface and will be
  done together in a later pass. Until then URLs render as banners (see
  [Banners](#banners)).
- **`AddPagerView` and `SettingsView` chrome.** They stay native macOS.
  `SettingsView` only *gains* the two theme pickers where the `ColorPicker` was.
- **The menu bar item's own rendering.** Text and image thumbnail keep their
  current shape; only their *color* becomes theme-derived.

## Visual reference

The target is the Motorola Memo Classic: chunky rounded case, a dark bezel ring
hugging a backlit LCD, a two-key rocker with continuous shared edges, and a
separate oval key set apart to its right.

Layout is **screen-forward** — a thin case frame with the LCD dominating, rather
than a full device body with nameplate:

```
╭──────────────────────────────────────────────╮
│ ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓ │
│ ┃▓ offline, will sync when back online    ▓┃ │ ← top banner (inverted)
│ ┃                                          ┃ │
│ ┃  party starts at 8.30                    ┃ │
│ ┃  ┌────────────────┐                      ┃ │
│ ┃  │     image      │                      ┃ │ ← image below text
│ ┃  └────────────────┘                      ┃ │
│ ┃▓ july.dev/pager                         ▓┃ │ ← link banner
│ ┃▓ New version available. update now  hide ▓┃ │ ← update banner
│ ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛ │
│  LIMINAL      ╱  C  ╱  ···  ╱ ✕╲    ╭──→──╮  │
╰──────────────────────────────────────────────╯
   ↑ debossed     ↑ one rocker unit    ↑ separate,
                            ↑ smaller,   green
                              red
```

The window height follows content: it grows as text wraps, as an image lands,
and as banners appear.

## Components

### 1. `Theme` (PagerCore)

Pure data, no AppKit, so the palette table is unit-testable and the layering
stays honest. The `Pager` target maps hex → `Color` at the view boundary.

```swift
public enum ScreenColor: String, Codable, CaseIterable {
    case green, blue, pink, orange, yellow, red, indigo
}
public enum CaseColor: String, Codable, CaseIterable {
    case darkGrey, beige
}
```

Neither enum resolves to a single color. Each resolves to a **role palette**:

| `ScreenPalette` role | drives |
|---|---|
| `backlight` | the lit LCD field |
| `ink` | text on the LCD — tinted toward the hue, never pure black |
| `glow` | bloom bleeding from the lit panel onto the bezel |
| `menuBarInk` | menu bar text + image thumbnail border (see below) |

| `CasePalette` role | drives |
|---|---|
| `shellTop`, `shellBottom` | body gradient stops |
| `edgeHighlight`, `edgeShadow` | the bevel pair |
| `bezel` | dark ring hugging the LCD |
| `keyTop`, `keyBottom`, `keyEdge` | rocker keys |
| `sendTop`, `sendBottom` | the green send key (constant across cases) |
| `brandInk`, `brandHighlight` | the debossed `LIMINAL` wordmark |

Roles are **opaque hex strings**. Alpha stays in the view layer — the palette
describes color identity; views decide rendering. This keeps blur and opacity
decisions out of the data table.

`darkGrey` is the primary case and gets the most tuning; `beige` is secondary.

**`menuBarInk` is a pair, not a single value.** Today the menu bar falls back to
`NSColor.labelColor`, which adapts to light/dark automatically. A fixed light
variant would be invisible on a light menu bar (yellow especially), so
`menuBarInk` carries a light-menu-bar and a dark-menu-bar variant, selected via
`NSApp.effectiveAppearance`. Same one-color-per-friend UX, legible in both.

**Assignment.** New pagers auto-assign so multiple pagers differ on sight:

```swift
ScreenColor.nextUnused(taken: [ScreenColor]) -> ScreenColor
```

Pure, testable, cycles `allCases` in order and wraps once all 7 are used.
Default case color is `.darkGrey`.

### 2. `AppearancePrefs` change (PagerCore)

```swift
public var screenColor: ScreenColor   // assigned at creation
public var caseColor: CaseColor       // default .darkGrey
// public var colorHex: String?       // REMOVED
```

`maxWidth`, `fontSize`, and `opacity` are untouched.

**Migration: none, by decision.** Old `colorHex` values are *not* snapped to the
nearest new color. `init(from:)` is already hand-written, so dropping the key
means stored values are simply ignored. The two new keys use
`decodeIfPresent ?? default`, so links saved before this change decode without
throwing. That non-throwing decode is a required test.

Removing `colorHex` has three knock-on edits beyond its two call sites:

- `Tests/PagerCoreTests/LinkStoreTests.swift:54,59` asserts `colorHex` round-trips
  through persistence. It is rewritten to assert `screenColor`/`caseColor`
  instead.
- `TextUtil.hex(from:)` (`NSColor` → hex) becomes unused once the `ColorPicker`
  is gone, and is deleted.
- `TextUtil.color(fromHex:)` is **kept** — the theme layer uses it to map palette
  hex strings to colors.

### 3. `EditorSession` changes (PagerCore)

The persistent window means closing is no longer the only commit point, so the
commit model becomes explicit. Two new methods on the existing seam:

- **`clear()`** — empties text *and* image, leaves `dirty = true`, does **not**
  commit. Generalizes the current `clearImage()`.
- **`discard()`** — reverts `content` to `store.cachedContent(id:)` and sets
  `dirty = false`.

`commit()` is unchanged.

Note that `discard()` reverting to *cached* content means a remote update that
arrived mid-edit wins. That is correct and consistent with the existing LWW rule.

### 4. `PagerWindowPlacement` (PagerCore)

```swift
PagerWindowPlacement.frame(
    size: CGSize, in visibleFrame: CGRect, avoiding occupied: [CGRect]
) -> CGRect
```

Pure, so it is testable without a screen. Anchors top-right below the menu bar,
then steps down-left while the candidate intersects an already-open pager.
Because every pager's frame is known, this is exact overlap avoidance rather
than blind index cascading; it falls back to a fixed index-based offset only if
it runs out of screen.

Once a window has been dragged, the persisted `windowFrame` takes over.

### 5. `PagerLink` change (PagerCore)

Adds `windowFrame: CGRect?` — the last dragged position, `nil` until first
dragged. `decodeIfPresent`, like `cachedIsImage` before it. A draggable window
that forgets where it was is broken, so this is required, not optional.

### 6. Chrome components (Pager)

New `Sources/Pager/UI/Chrome/`, one job per file:

- **`PagerShell`** — case body gradient, bevel pair, noise overlay; a container
  taking a `CasePalette`.
- **`LCDPanel`** — bezel stroke stack, backlight fill, inner shadow, outer glow.
- **`KeyShapes`** — custom `Shape` types from cubic béziers. Explicitly **not**
  `Capsule`/`Ellipse`/`RoundedRectangle`; a validation spike using stock shapes
  read as a generic ellipse rather than a molded key. Profiles are hand-tuned
  through `design-preview`. The three rocker keys share continuous diagonal
  edges so they read as one molded part split by dividers; the send key is a
  separate oval.
- **`NoiseTexture`** — `CIRandomGenerator` → desaturated → 128×128 tile →
  `static let` cached `NSImage`, tiled at ~3% with `.blendMode(.overlay)`,
  generated once per process.
- **`Banner`** — the inverted-video row (`backlight` text on `ink` ground).

`UI/PopoverView.swift` is renamed to `UI/PagerDeviceView.swift` and rewritten to
compose the above. The name `PopoverView` stops being accurate once the popover
is gone. It stays a thin shell over `LinkViewModel`, per the repo's
core-vs-views boundary — the chrome is presentation, and every decision it
renders comes from `PagerCore`.

**Bevels need stroke stacks, not just inner shadow.** Native
`.fill(color.shadow(.inner(...)))` (macOS 13+, matches the deployment target) is
available but subtle; the spike showed it alone does not make the LCD read as
recessed. Hard edges come from overlaid strokes layered with it.

**Everything inside the LCD is inked in `ink`,** including the placeholder and
the caret (`.tint(ink)`). A blue system caret blinking on a green LCD breaks the
illusion instantly.

Keys get a pressed state via `ButtonStyle` reading `configuration.isPressed`:
the bevel inverts and the key sinks 1pt.

`LIMINAL` is rendered debossed — case-colored text with a dark inner offset and
a 1px light edge below, so it reads as molded into the shell.

### <a name="banners"></a>7. Banners

Banners live **inside** the LCD in inverted video, like a real LCD status row.
Vertical order:

1. **Offline** — pinned top, above all content.
2. *(content: text, then image)*
3. **Link banners** — one per detected URL, clickable.
4. **Update** — pinned bottom: `New version available. [update now] [hide me]`.

Banners are separated by a 1px gap, reading as one LCD pixel at this scale.

`hide me` needs a **persisted dismissed-version flag** — the dismissed version
string in `UserDefaults`, app-wide rather than per-link, so the banner stays
hidden for that version but returns for the next one.

Link banners exist because `TextField` — SwiftUI or `NSTextField` — cannot host
a clickable link: the field editor treats every click as caret placement. This
is the deferred `NSTextView` work; banners are the interim, and they are
visually coherent because banners are already the established idiom here.

### 8. `PagerWindow` (Pager) — replaces `NSPopover`

A borderless `NSWindow` subclass:

- `level = .floating` — always on top.
- `isMovableByWindowBackground = true` — draggable anywhere on the case.
- `isOpaque = false`, clear background, `hasShadow = false`.
- `override var canBecomeKey: Bool { true }` — **required**; borderless windows
  refuse key status otherwise and the text field would never take focus.
- **Shadow drawn in SwiftUI, not by AppKit.** The window's own shadow cannot
  animate, and the shadow must soften when focus is lost. Drawing it means the
  content is inset by a shadow margin and focus state animates radius/opacity.
- Focus tracked via `didBecomeKey` / `didResignKey`.
- Height follows content.
- One window per link, mutually independent; several may be open at once.

There is no transient dismissal and no menu-bar proximity requirement, which is
what makes retiring `NSPopover` correct rather than merely possible.

### 9. Commit model

| Trigger | Draft | Window |
|---|---|---|
| `→` send key, or `↩` | **commit** | close |
| `✕` close key | **discard** | close |
| `C` clear key | **clear**, stays dirty | stays open, still editing |
| menu bar click, window focused | **commit** | close |
| menu bar click, window unfocused | — | raise + focus |
| menu bar click, window closed | — | open at its placed frame |

`↩` alone commits — the field holds no newlines, so no `⌘↩` special case is
needed and the existing `onSubmit` path already does this.

### 10. `StatusItemController` changes (Pager)

- `renderText` uses `menuBarInk` (appearance-selected) instead of `colorHex`.
- `thumbnail` strokes its border in `menuBarInk` instead of `NSColor.labelColor`.
- Click behavior follows the commit table above.
- The anchor sliver (`StatusItemController:11-14`) becomes dead code — it exists
  only to stop the popover drifting as the button widens — and is removed.

### 11. `DesignPreview` (new target)

A dev-only SwiftPM executable rendering the real chrome to PNG via SwiftUI's
`ImageRenderer` (macOS 13+). Headless: no window, no app launch, no permissions.

```sh
swift run design-preview --out /tmp/pager.png
swift run design-preview --sheet --out /tmp/sheet.png   # all 7 × 2, all states
swift run design-preview --screen indigo --case beige --state image
```

The contact sheet renders every theme combination plus the states easy to
forget: empty, long wrapping text, image attached, offline, update available.

It renders the **actual** chrome views, not a copy, so it cannot drift.

It must **not** ship: `make bundle` copies specific binaries, and
`design-preview` stays off that list. It adds no dependency to the `Pager`
product.

## Development feedback loop

Two tiers, answering different questions.

**Tier 1 — `swift run design-preview`.** Fast, deterministic, no permissions.
Used for essentially all chrome iteration. Validated by a working spike before
this spec was written.

**Tier 2 — the real app.** `ImageRenderer` has real blind spots: it does not
faithfully render materials/vibrancy, shows no live caret, and knows nothing
about how the chrome sits in the actual window. So a debug hook:

```sh
PAGER_DEBUG_WINDOW=1 swift run Pager
#   → opens the first link's window immediately
#   → prints its frame: PAGER_FRAME 1204,38,360,190
screencapture -R 1204,38,360,190 -x /tmp/real.png
```

~6 lines in `AppDelegate` behind an env var. No third-party dependency and no
accessibility permissions; `screencapture` is confirmed working in this
environment.

Tier 1 is fast but slightly lies. Design against tier 1, confirm against tier 2.

> Rejected alternatives: **Peekaboo** requires macOS Sequoia and cannot run on
> this machine (14.5). **XcodeBuildMCP** is a poor fit — there is no Xcode
> project; `swift build` and `make bundle` already work.

`.accessibilityIdentifier()` is applied to the chrome views regardless: cheap,
and it pays off if a regression suite is ever added.

## Testing

Per the repo's core-vs-views boundary, every decision is testable offline.

**`swift test`:**
- palette tables are complete for all 7 × 2 — no role silently missing
- `nextUnused` cycling and wrap-around
- `AppearancePrefs` decodes links saved **before** this change (the `colorHex`
  removal must not throw)
- `EditorSession.clear()` empties content and leaves the draft dirty
- `EditorSession.discard()` reverts to cached content and clears dirty
- `PagerWindowPlacement` overlap avoidance and screen-exhaustion fallback

**`swift run design-preview --sheet`** — the visual pass.

**`swift run e2e`** before shipping, since `EditorSession` sits on the sync path.

**Manual** — the GUI last mile, via tier 2 capture.

## Risks

1. **Retiring `NSPopover`** requires re-verifying the `⌘V` local key monitor
   (commit `d8b813e`), focus, and commit-on-close against a key window. This is
   the likeliest regression site.
2. **`ImageRenderer` fidelity** will not perfectly match the real window; expect
   a correction round after the first tier-2 screenshot.
3. **Key shapes are iterative.** The bézier profiles are the one part that
   cannot be specified in advance — they are tuned visually against the
   reference.
