# Skeuomorphic Reskin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reskin Pager so each link renders as a per-link-themed physical pager — molded case, recessed backlit LCD — in a draggable always-on-top window replacing the transient popover.

**Architecture:** Theme data and every decision live in `PagerCore` (pure, testable). A new `PagerUI` library holds the presentational chrome, driven entirely by props so it can be rendered headlessly. `Pager` adapts its live models onto that view; `DesignPreview` renders the same views to PNG for a closed visual loop.

**Tech Stack:** SwiftPM (no Xcode project), SwiftUI + AppKit, `ImageRenderer` (macOS 13+), CoreImage for the noise tile. No new third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-08-05-skeuomorphic-reskin-design.md`

## Global Constraints

- Deployment target is **macOS 13** (`Package.swift`). `.fill(color.shadow(.inner(...)))` and `ImageRenderer` are available; nothing newer may be used.
- **No new third-party dependencies.** Sparkle remains the only one.
- `PagerCore` holds every decision worth testing. **If a view contains a decision, it belongs in `PagerCore`.**
- **A pager holds text OR an image, never both.**
- Max text length **500** chars; PUT debounce **~300ms**; LWW keyed on `writtenAt`, ties by `updatedBy`.
- Log events for images carry `ct_len` only, never image ciphertext.
- `design-preview` must **never** ship — keep it out of `make bundle`.
- All new user-facing copy is **lowercase**, matching existing UI strings ("type a message…", "quit pager").
- Every new chrome view gets an `.accessibilityIdentifier()`.

## Deviation from the spec (read before Task 3)

The spec places chrome in `Sources/Pager/UI/Chrome/` and has `DesignPreview`
render it. **That does not build:** `Pager` is an `executableTarget`, and SwiftPM
targets cannot import executables.

Resolution: a new **`PagerUI` library target** holding the chrome and a
**props-driven** `PagerDeviceView`. It takes a plain state struct, not
`LinkViewModel`/`UpdateController`. `Pager` keeps a thin adapter mapping its live
models onto those props; `DesignPreview` passes literal props.

This is strictly better than the spec's arrangement — it forces the device view
to be genuinely dumb (the repo's stated boundary), and makes rendering every
visual state trivial, since a state is just a value.

## File structure

| Target | Path | Responsibility |
|---|---|---|
| PagerCore | `Theme/ScreenColor.swift` | screen enum + `ScreenPalette` table + `nextUnused` |
| PagerCore | `Theme/CaseColor.swift` | case enum + `CasePalette` table |
| PagerCore | `Models/PagerLink.swift` *(mod)* | `AppearancePrefs` theme fields; `windowFrame` |
| PagerCore | `Models/EditorSession.swift` *(mod)* | `clear()`, `discard()` |
| PagerCore | `Window/PagerWindowPlacement.swift` | pure first-open frame placement |
| PagerUI | `Chrome/NoiseTexture.swift` | cached procedural noise tile |
| PagerUI | `Chrome/PagerShell.swift` | case body, bevel, noise, debossed wordmark |
| PagerUI | `Chrome/LCDPanel.swift` | bezel, backlight, inner shadow, glow |
| PagerUI | `Chrome/Banner.swift` | inverted-video LCD row |
| PagerUI | `Chrome/KeyShapes.swift` | bézier key shapes + pressed `ButtonStyle` |
| PagerUI | `PagerDeviceState.swift` | the props contract |
| PagerUI | `PagerDeviceView.swift` | composes all of the above |
| Pager | `UI/PagerDeviceAdapter.swift` | `LinkViewModel`+`UpdateController` → props |
| Pager | `App/PagerWindow.swift` | borderless floating window |
| Pager | `App/StatusItemController.swift` *(mod)* | themed ink, toggle/raise behavior |
| Pager | `Settings/SettingsView.swift` *(mod)* | swatch pickers |
| DesignPreview | `main.swift` | CLI → PNG / contact sheet |

Deleted: `Sources/Pager/UI/PopoverView.swift`, `TextUtil.hex(from:)`.

---

## Task 1: Theme data model

**Files:**
- Create: `Sources/PagerCore/Theme/ScreenColor.swift`, `Sources/PagerCore/Theme/CaseColor.swift`
- Test: `Tests/PagerCoreTests/ThemeTests.swift`

**Interfaces — Produces:**
```
enum ScreenColor: String, Codable, CaseIterable { green, blue, pink, orange, yellow, red, indigo }
enum CaseColor:   String, Codable, CaseIterable { darkGrey, beige }

struct ScreenPalette { backlight, ink, glow, menuBarInkOnLight, menuBarInkOnDark: String }  // "#RRGGBB"
struct CasePalette   { shellTop, shellBottom, edgeHighlight, edgeShadow, bezel,
                       keyTop, keyBottom, keyEdge, sendTop, sendBottom,
                       brandInk, brandHighlight: String }

ScreenColor.palette: ScreenPalette      // total, no optionals
CaseColor.palette:   CasePalette
static ScreenColor.nextUnused(taken: [ScreenColor]) -> ScreenColor
```

**Intent:** Palettes are *opaque hex only*. Alpha, blur, and blend modes are
rendering decisions and stay in the views — if a palette field ever needs an
alpha channel, that's a signal the role is under-specified. `menuBarInk` is a
**pair** because the menu bar background differs by system appearance and a
single light value would vanish on a light menu bar.

Hex values are a first pass; they get tuned visually from Task 3 onward. Pick
`ink` tinted toward its hue (a green LCD's text is very dark green, not black).

- [ ] **Step 1:** Write `ThemeTests` covering: every `ScreenColor` and `CaseColor` case returns a palette whose every field is a valid `#RRGGBB` string (drive with `allCases`, so adding a case later fails the test rather than silently defaulting); `nextUnused` returns the first unused in `allCases` order; `nextUnused` wraps to `.green` when all 7 are taken; `nextUnused(taken: [])` returns `.green`.
- [ ] **Step 2:** Run `swift test --filter ThemeTests` — expect failure (types don't exist).
- [ ] **Step 3:** Implement both enums and palette tables.
- [ ] **Step 4:** Run `swift test --filter ThemeTests` — expect pass.
- [ ] **Step 5:** Commit.

**Acceptance:** All 9 enum cases have complete palettes. Test is `allCases`-driven, so a future 8th screen color fails loudly. No AppKit import in either file.

---

## Task 2: Persistence migration

**Files:**
- Modify: `Sources/PagerCore/Models/PagerLink.swift`, `Sources/PagerCore/TextUtil.swift`
- Modify: `Tests/PagerCoreTests/LinkStoreTests.swift:52-59`
- Test: `Tests/PagerCoreTests/AppearancePrefsTests.swift` (new)

**Interfaces — Consumes:** `ScreenColor`, `CaseColor` (Task 1).
**Produces:** `AppearancePrefs.screenColor`, `.caseColor`; `PagerLink.windowFrame: CGRect?`.

**Intent:** `colorHex` is deleted with **no migration** — old values are not
snapped to the nearest new color (explicit product decision). The risk isn't
losing the color, it's *throwing on decode* and wiping a user's links. That's
the one thing that must not happen.

`init(from:)` is already hand-written in both types, so: drop `colorHex` from the
property list and `CodingKeys`; add the new keys with `decodeIfPresent ?? default`.
`CGRect` is `Codable` already.

The existing `LinkStoreTests` round-trip asserts `colorHex` — rewrite it to
assert the theme fields rather than deleting the coverage. `TextUtil.hex(from:)`
loses its only caller (the `ColorPicker`) and is deleted; `color(fromHex:)` is
**kept**, since the theme layer maps palette hex to colors.

- [ ] **Step 1:** Write `AppearancePrefsTests`: decoding a JSON blob shaped like a **pre-change** saved link (has `colorHex`, lacks `screenColor`/`caseColor`) succeeds, preserves `maxWidth`/`fontSize`/`opacity`, and yields defaults `.green`/`.darkGrey`. Also: a `PagerLink` JSON without `windowFrame` decodes with `nil`. Also: round-trip of new fields through encode/decode.
- [ ] **Step 2:** Run — expect failure.
- [ ] **Step 3:** Apply the model changes; update `LinkStoreTests:52-59` to assert `screenColor`/`caseColor`; delete `TextUtil.hex(from:)`.
- [ ] **Step 4:** Run full `swift test` — expect pass. `swift build` will still fail on `StatusItemController:71` and `SettingsView:155-166`; that's expected and fixed in Tasks 10–11. **Do not** patch them here beyond what's needed to compile — if a temporary stub is required, use `ScreenColor.green.palette` and leave a comment pointing at the owning task.
- [ ] **Step 5:** Commit.

**Acceptance:** A pre-change link decodes without throwing and gets default theme values. No `colorHex` remains anywhere (`grep -rn colorHex --include=*.swift .` is empty).

---

## Task 3: `PagerUI` target, noise, shell, and the visual loop

**Files:**
- Modify: `Package.swift`
- Create: `Sources/PagerUI/Chrome/NoiseTexture.swift`, `Sources/PagerUI/Chrome/PagerShell.swift`
- Create: `Sources/DesignPreview/main.swift`

**Interfaces — Consumes:** `CaseColor`/`CasePalette` (Task 1).
**Produces:**
```
NoiseTexture.tile: NSImage                       // cached, generated once
PagerShell<Content: View>(palette: CasePalette, content: () -> Content)
// CLI: design-preview [--case <name>] [--out <path>]
```

**Intent:** This task exists to get the feedback loop working *before* the
detailed chrome, so everything after it is visually verifiable. Ship the ugliest
case that renders, then iterate.

`PagerUI` is a **library** target (see the deviation note above) — `Pager`,
`DesignPreview` both depend on it; it depends on `PagerCore`. `DesignPreview`
must not be added to `make bundle`'s copy list.

Two things carry the whole illusion here:
- **Noise.** Flat plastic reads as a rounded rectangle. Generate once via
  CoreImage `CIRandomGenerator` → desaturate → crop to a 128×128 tile → cache in
  a `static let`. Tile it with `.resizable(resizingMode: .tile)` at ~3% opacity,
  `.blendMode(.overlay)`. Regenerating per frame would be a real performance bug.
- **Bevel.** A validation spike showed native `.shadow(.inner(...))` alone is too
  subtle to read as molded. Combine it with overlaid strokes: `edgeHighlight`
  along the top inner edge, `edgeShadow` along the bottom.

`ImageRenderer` is `@MainActor`; from `main.swift` top-level code, wrap the call
in `MainActor.assumeIsolated { }` or it won't compile.

- [ ] **Step 1:** Add `PagerUI` library target and `DesignPreview` executable (product name `design-preview`) to `Package.swift`. Verify `swift build` succeeds.
- [ ] **Step 2:** Implement `NoiseTexture` with a unit test asserting the tile is non-nil, is 128×128, and that two accesses return the identical cached instance.
- [ ] **Step 3:** Implement `PagerShell`.
- [ ] **Step 4:** Implement `design-preview` rendering a shell with placeholder content to PNG at `scale = 2`.
- [ ] **Step 5:** Run `swift run design-preview --case darkGrey --out /tmp/shell.png`, **open the PNG and look at it.** Iterate the gradient/bevel/noise values until it reads as molded plastic rather than a grey rectangle. Repeat for `beige`.
- [ ] **Step 6:** Confirm `design-preview` is absent from `make bundle` output: `make bundle && ls dist/Pager.app/Contents/MacOS/`.
- [ ] **Step 7:** Commit.

**Acceptance:** `swift run design-preview` writes a PNG. The case reads as molded plastic with visible bevel and surface texture. `dist/Pager.app` contains no `design-preview` binary.

---

## Task 4: LCD panel and banners

**Files:**
- Create: `Sources/PagerUI/Chrome/LCDPanel.swift`, `Sources/PagerUI/Chrome/Banner.swift`
- Modify: `Sources/DesignPreview/main.swift`

**Interfaces — Consumes:** `ScreenPalette`, `PagerShell`.
**Produces:**
```
LCDPanel<Content: View>(palette: ScreenPalette, content: () -> Content)
Banner(palette: ScreenPalette, style: .plain | .action, ...)   // inverted video
// CLI gains: --screen <name>
```

**Intent:** The LCD must read as *recessed and lit*, which is three separate
effects — don't stop after the first:
1. **Sunk:** inner shadow + a dark `bezel` stroke ring around the panel.
2. **Lit:** an outer glow bleeding `glow` onto the surrounding case
   (`.shadow(color: glow, radius: …)` on the panel).
3. **Inked:** all content in `ink`, never `.primary`.

Banners are inverted video — `backlight` text on an `ink` ground — mimicking a
real LCD status row. Separate stacked banners by a **1pt** gap, reading as one
LCD pixel at this scale. `.action` style carries tappable words (`update now`,
`hide me`).

- [ ] **Step 1:** Implement `LCDPanel` and `Banner`.
- [ ] **Step 2:** Extend `design-preview` with `--screen`, rendering a panel containing sample text plus a stacked offline + update banner.
- [ ] **Step 3:** Render and **look at** all 7 screen colors against both cases. Check specifically: does `ink` stay legible on every backlight (yellow and orange are the risky ones)? Does the glow read without washing out the bezel? Tune palettes from Task 1 as needed.
- [ ] **Step 4:** Commit.

**Acceptance:** Panel reads as recessed and backlit. All 7 screen colors have legible `ink`. Banners are visibly inverted with a 1pt separation.

---

## Task 5: Keys and wordmark

**Files:**
- Create: `Sources/PagerUI/Chrome/KeyShapes.swift`
- Modify: `Sources/PagerUI/Chrome/PagerShell.swift`, `Sources/DesignPreview/main.swift`

**Interfaces — Produces:**
```
struct RockerKey: Shape { enum Position { leading, middle, trailing } }
struct SendKey: Shape
struct PagerKeyButtonStyle: ButtonStyle
```

**Intent:** This is the task that **cannot be specified in advance** — the bézier
profiles are pure visual iteration. Budget several render-look-adjust rounds.

Hard requirements, because a validation spike using stock shapes read as a
generic ellipse:
- Built from **cubic béziers**. `Capsule`, `Ellipse`, `RoundedRectangle` are
  forbidden for the keys.
- The three rocker keys (`C`, `···`, `✕`) share **continuous diagonal edges** —
  one molded part split by thin dividers, not three separate buttons. Practically:
  one silhouette path, with each key's shape a region of it, so adjacent edges
  are identical lines rather than two independently-rounded borders that leave a
  lens-shaped gap.
- `✕` is **smaller and red**; the send key is a **separate green oval**, set
  apart to the right of the rocker.
- Pressed state via `configuration.isPressed`: bevel inverts, key sinks 1pt.
  Static keys feel dead.

`LIMINAL` sits at the left of the key row, **debossed**: case-colored text with a
dark inner offset and a 1px `brandHighlight` edge *below* it. The light-below
edge is what sells "stamped into plastic" — the opposite order reads as embossed.

- [ ] **Step 1:** Implement the shapes and button style; place the key row and wordmark in `PagerShell`.
- [ ] **Step 2:** Extend `design-preview` to render normal and pressed states.
- [ ] **Step 3:** Render and **look at** it against the reference. Iterate until the keys read as molded — specifically that the rocker looks like one part, not three pills. Verify pressed state is visible.
- [ ] **Step 4:** Commit.

**Acceptance:** Keys use only bézier `Shape` types. Rocker reads as a single molded unit. `✕` is smaller and red, send key is a separate green oval. Pressed state visibly sinks. `LIMINAL` reads as stamped into the case.

---

## Task 6: `PagerDeviceView` and the contact sheet

**Files:**
- Create: `Sources/PagerUI/PagerDeviceState.swift`, `Sources/PagerUI/PagerDeviceView.swift`
- Modify: `Sources/DesignPreview/main.swift`

**Interfaces — Produces:**
```
struct PagerDeviceState {
    screenColor: ScreenColor; caseColor: CaseColor    // names match AppearancePrefs
    text: String; imageData: Data?
    isWindowFocused: Bool
    isOffline: Bool
    updateBanner: (version: String)?
    links: [URL]
}
struct PagerDeviceActions { onTextChange, onSubmit, onSend, onClose, onClear,
                            onMenu, onOpenURL, onUpdateNow, onHideUpdate }
PagerDeviceView(state:actions:)
// CLI gains: --sheet, --state <empty|long|image|offline|update>
```

**Intent:** Props in, callbacks out — **no** `LinkViewModel`, **no**
`UpdateController`, no `@ObservedObject`. That's what lets `design-preview`
render any state as a literal value, and it keeps the view genuinely dumb.

Vertical order inside the LCD is fixed: offline banner → text → image → link
banners (one per URL) → update banner. Offline pins top, update pins bottom.

Content-driven height: the view must not hard-code a height; the window (Task 9)
reads its fitting size. Width stays fixed at 360.

Caret must be `.tint(ink)` — a blue system caret on a green LCD breaks the
illusion instantly. Placeholder stays `"type a message…"`.

- [ ] **Step 1:** Define the state/actions structs and implement the view.
- [ ] **Step 2:** Implement `--sheet`: every screen color × case color, plus each named state.
- [ ] **Step 3:** Render the sheet and **look at every cell.** Check the states that are easy to get wrong: empty, long wrapping text, image attached, offline + update banners simultaneously.
- [ ] **Step 4:** Add `.accessibilityIdentifier()` to each interactive element.
- [ ] **Step 5:** Commit.

**Acceptance:** `swift run design-preview --sheet` renders all 14 combinations and all named states in one PNG. `PagerDeviceView` imports neither `LinkViewModel` nor `UpdateController`. Height varies with content.

---

## Task 7: `EditorSession.clear()` / `discard()`

**Files:**
- Modify: `Sources/PagerCore/Models/EditorSession.swift`
- Test: `Tests/PagerCoreTests/EditorSessionTests.swift`

**Interfaces — Produces:** `EditorSession.clear()`, `EditorSession.discard()`.

**Intent:** The persistent window means closing is no longer the only commit
point, so the model needs explicit verbs. The distinction that matters:

- `clear()` — empties text *and* image, **stays dirty**, does **not** commit.
  Generalizes the existing `clearImage()`. The user is still editing.
- `discard()` — reverts `content` to `store.cachedContent(id:)` and sets
  `dirty = false`.

`discard()` reverting to *cached* means a remote update that arrived mid-edit
wins. That is intentional and consistent with LWW — don't "fix" it by snapshotting
content at session start.

- [ ] **Step 1:** Write tests: `clear()` from a text draft empties it and leaves dirty true; `clear()` from an image draft empties both and leaves dirty true; `discard()` after edits restores cached content and leaves dirty false; `commit()` after `discard()` pushes nothing (guarded by `dirty`); `discard()` picks up a remote value that landed mid-edit.
- [ ] **Step 2:** Run — expect failure.
- [ ] **Step 3:** Implement; fold `clearImage()` into `clear()` and update its callers.
- [ ] **Step 4:** Run `swift test` — expect pass.
- [ ] **Step 5:** Commit.

**Acceptance:** Both verbs behave per the table. No commit occurs on `clear()`. `commit()` after `discard()` is a no-op.

---

## Task 8: `PagerWindowPlacement`

**Files:**
- Create: `Sources/PagerCore/Window/PagerWindowPlacement.swift`
- Test: `Tests/PagerCoreTests/PagerWindowPlacementTests.swift`

**Interfaces — Produces:**
```
PagerWindowPlacement.frame(size: CGSize, in visibleFrame: CGRect,
                           avoiding occupied: [CGRect]) -> CGRect
```

**Intent:** Pure function, no AppKit, so overlap behavior is testable without a
screen. Anchors **top-right**, then steps down-left while the candidate
intersects an already-open pager. Because every pager's frame is known, this is
exact avoidance, not blind index cascading.

Tricky bit — the loop needs a termination guard, or a crowded screen spins:

```
candidate = topRight(size, visibleFrame, inset)
for step in 0..<maxSteps:
    if no r in occupied intersects candidate: return candidate
    candidate = candidate offset by (-stepX, -stepY)
    if candidate escapes visibleFrame: break
return topRight offset by ((attemptIndex % 5) * stepX, ...)   // clamped cascade
```

The fallback must stay **inside** `visibleFrame` — a window placed off-screen is
unrecoverable for the user, since they can't drag what they can't see.

- [ ] **Step 1:** Write tests: no occupied → top-right corner, inset; one occupied at top-right → result doesn't intersect it; occupied filling the screen → result still lies within `visibleFrame`; result size always equals requested size; multi-monitor `visibleFrame` with non-zero origin is respected (a common bug — don't assume origin is `.zero`).
- [ ] **Step 2:** Run — expect failure.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run — expect pass.
- [ ] **Step 5:** Commit.

**Acceptance:** Never returns a frame outside `visibleFrame`. Never loops forever. Avoids overlap when space allows.

---

## Task 9: `PagerWindow`

**Files:**
- Create: `Sources/Pager/App/PagerWindow.swift`, `Sources/Pager/UI/PagerDeviceAdapter.swift`
- Modify: `Sources/Pager/App/StatusItemController.swift`, `Sources/Pager/App/AppDelegate.swift`
- Delete: `Sources/Pager/UI/PopoverView.swift`

**Interfaces — Consumes:** `PagerWindowPlacement`, `PagerDeviceView`, `PagerLink.windowFrame`.
**Produces:** `PagerWindow` with `show()`, `close()`, `isFocused`, `onFrameChanged`.

**Intent:** **This is the riskiest task in the plan** — it retires `NSPopover`
and everything built around it. Expect to re-verify the `⌘V` paste monitor
(commit `d8b813e`), focus, and commit-on-close.

Non-obvious requirements, each of which will silently break things if missed:

- `override var canBecomeKey: Bool { true }` — **borderless windows refuse key
  status by default**, and without it the text field can never take focus. This
  is the single most common way this task fails.
- `hasShadow = false`; the shadow is drawn in SwiftUI instead, because AppKit's
  window shadow can't animate and it must soften on focus loss. Consequence: the
  content is inset by a shadow margin, so the window is larger than the visible
  device — placement and drag math must use the **visible** rect, not the window
  frame, or the pager will look mis-positioned.
- `level = .floating`, `isMovableByWindowBackground = true`, `isOpaque = false`,
  clear `backgroundColor`.
- Focus via `didBecomeKey`/`didResignKey` → animate shadow radius/opacity.
- Persist `windowFrame` on drag end (`didMove`), debounced — don't write to
  `UserDefaults` on every frame of a drag.
- The anchor sliver (`StatusItemController:11-14`) exists only to stop popover
  drift and becomes dead code. Remove it and `dropView`'s popover coupling stays intact.

Also add the tier-2 debug hook: `PAGER_DEBUG_WINDOW=1` opens the first link's
window at launch and prints `PAGER_FRAME x,y,w,h` to stdout.

- [ ] **Step 1:** Implement `PagerWindow` hosting `PagerDeviceView` via `NSHostingView`, with a `PagerDeviceAdapter` mapping `LinkViewModel` + `UpdateController` onto props.
- [ ] **Step 2:** Replace the popover in `StatusItemController` with window show/close. Delete `PopoverView.swift` and the anchor sliver.
- [ ] **Step 3:** Add the `PAGER_DEBUG_WINDOW` hook.
- [ ] **Step 4:** `swift run Pager` and verify **by hand**: window appears top-right; drags; stays above other apps; shadow softens when another app takes focus; text field focuses and accepts typing; **⌘V of an image still works without a beep**; two links open two non-overlapping windows.
- [ ] **Step 5:** Tier-2 capture: `PAGER_DEBUG_WINDOW=1 swift run Pager`, then `screencapture -R <frame> -x /tmp/real.png`, and **compare against the tier-1 render.** Fix divergences.
- [ ] **Step 6:** Commit.

**Acceptance:** Window is draggable, floating, focus-reactive. Text field takes focus. Image paste works. Position persists across relaunch. Two pagers don't overlap on first open.

---

## Task 10: Commit model and menu bar behavior

**Files:**
- Modify: `Sources/Pager/App/StatusItemController.swift`, `Sources/Pager/App/AppDelegate.swift`, `Sources/Pager/UI/PagerDeviceAdapter.swift`

**Interfaces — Consumes:** `EditorSession.clear()`/`discard()`/`commit()`, `PagerWindow`.

**Intent:** Wire the four affordances to the verbs from Task 7. The full table —
implement exactly this:

| Trigger | Draft | Window |
|---|---|---|
| `→` send, or `↩` | `commit()` | close |
| `✕` close | `discard()` | close |
| `C` clear | `clear()` | **stays open, still editing** |
| menu bar click, window focused | `commit()` | close |
| menu bar click, window **unfocused** | — | raise + focus |
| menu bar click, window closed | — | open at placed frame |

`↩` alone commits — the field holds no newlines, so there is no `⌘↩` case and the
existing `onSubmit` path already does this.

The focused/unfocused menu bar distinction is the subtle one: clicking the menu
bar item while the window is visible but *not* focused must **raise** it, not
close it. Closing a window the user can see but isn't focused on feels broken.

Also in this task: `StatusItemController.renderText` picks `menuBarInkOnDark` or
`menuBarInkOnLight` from the link's `ScreenPalette` by inspecting
`NSApp.effectiveAppearance`, instead of reading `colorHex`; and `thumbnail`
strokes its border with the same value instead of `NSColor.labelColor` — both
resolving the temporary stub left in Task 2. The existing `opacity` pref still
applies on top.

- [ ] **Step 1:** Implement the table and the `menuBarInk` wiring.
- [ ] **Step 2:** Verify **by hand**, every row: edit → `✕` reverts and the menu bar still shows the old text; edit → `→` commits; `C` empties but leaves the window open and focused; menu bar click while focused commits and closes; while unfocused raises.
- [ ] **Step 3:** Verify menu bar text takes the screen color and adapts between light and dark mode (toggle System Settings appearance and confirm both are legible).
- [ ] **Step 4:** Run `swift run e2e` — `EditorSession` is on the sync path.
- [ ] **Step 5:** Commit.

**Acceptance:** Every row of the table behaves as written. Menu bar ink is legible in both appearances. `e2e` passes.

---

## Task 11: Settings pickers

**Files:**
- Modify: `Sources/Pager/Settings/SettingsView.swift:150-168`

**Intent:** Replace the `ColorPicker` block with two swatch rows — screen color
(7) and case color (2). Swatches render the actual `backlight` / `shellTop`
color so the choice is visible, with a clear selected state. Settings chrome
stays native macOS; only this control changes.

New pagers auto-assign via `ScreenColor.nextUnused(taken:)` over the store's
existing links, so two pagers don't default to the same color.

- [ ] **Step 1:** Replace the `ColorPicker` with the two swatch rows.
- [ ] **Step 2:** Wire auto-assign into link creation (`PagerActions`/`LinkStore`), with a test that creating links yields distinct screen colors until the 7 are exhausted.
- [ ] **Step 3:** Verify by hand that changing either color updates the open window and the menu bar immediately.
- [ ] **Step 4:** Commit.

**Acceptance:** Both pickers present, showing real colors. Changes apply live. Consecutive new pagers get distinct screen colors.

---

## Task 12: Update banner persistence and docs

**Files:**
- Modify: `Sources/Pager/App/UpdateController.swift`, `Sources/PagerUI/PagerDeviceView.swift`, `AGENTS.md`

**Intent:** `hide me` stores the **dismissed version string** in `UserDefaults`,
app-wide. Storing a boolean is the bug to avoid — the banner must return for the
*next* version, so the check is `dismissedVersion != availableVersion`.

`AGENTS.md` is now stale in several places and must be corrected — it's the file
future agents read first: the target list gains `PagerUI`/`DesignPreview`; the
`Pager` layers section no longer has `PopoverView` or `NSPopover`; `AppearancePrefs`
no longer has `colorHex`; the Commands section gains `design-preview`.

- [ ] **Step 1:** Implement dismissed-version persistence.
- [ ] **Step 2:** Verify: dismiss the banner, relaunch, it stays hidden; simulate a newer version and confirm it reappears.
- [ ] **Step 3:** Update `AGENTS.md` (`CLAUDE.md` is a symlink — edit `AGENTS.md`).
- [ ] **Step 4:** Run `swift test` and `swift run e2e`.
- [ ] **Step 5:** `make bundle` and confirm the app launches from `dist/Pager.app` and contains no `design-preview`.
- [ ] **Step 6:** Commit.

**Acceptance:** Dismissal survives relaunch but resets on a new version. `AGENTS.md` describes the shipped architecture. Full test suite and e2e pass. Release bundle is clean.

---

## Deferred (explicitly not in this plan)

- Pixel/dot-matrix font and inline clickable links via an `NSTextView` bridge —
  the same surface, to be done together in a later pass.
- `AddPagerView` / `SettingsView` chrome — they stay native macOS.
- The menu bar item's shape — only its color becomes theme-derived.
