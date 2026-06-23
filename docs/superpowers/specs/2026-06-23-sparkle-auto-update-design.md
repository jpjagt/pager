# Sparkle Auto-Update — Design Spec

*2026-06-23 — approved via brainstorming session*

## Motivation

Pager ships as an ad-hoc-codesigned `.zip` hosted on july.dev. Today the only
way a user gets a new version is to notice it exists, re-download the zip, and
drag it over the old app — so in practice nobody updates. This spec adds
**in-app updates via [Sparkle](https://sparkle-project.org) 2**: the app checks
a hosted appcast in the background, and when a new version is available it
surfaces a **non-intrusive "Update now" affordance** (no modal popup) that
downloads, verifies, swaps, and relaunches in one click.

This is the lowest-friction option that fits the current architecture: it keeps
direct distribution from july.dev, requires no sandboxing, and adds exactly one
(reputable, well-audited) third-party dependency.

## Trust model & why notarization is not required (yet)

Sparkle's update integrity does **not** depend on Apple notarization. Its trust
anchor is its own **EdDSA signature** on each update: the app embeds a public
key (`SUPublicEDKey` in `Info.plist`), every released zip is signed with the
matching private key, and Sparkle refuses any update whose signature does not
verify. This is mandatory in Sparkle 2 and is what replaces notarization as the
integrity guarantee while we remain ad-hoc-signed.

Consequences of staying un-notarized **for now**:

- **First install is unchanged from today.** A brand-new user downloading the
  zip via a browser still hits the Gatekeeper "cannot verify developer" prompt
  (on Sequoia: System Settings → Privacy & Security → "Open Anyway"). Sparkle
  does not make this better or worse.
- **Sparkle-delivered updates are smooth.** Sparkle handles quarantine on the
  bundle it installs and the app is already trusted/running, so subsequent
  updates do not re-trigger Gatekeeper. One-time first-install friction, clean
  updates thereafter.
- **Ad-hoc signing has no stable identity across versions.** The one place this
  may bite is `SMAppService` LaunchAtLogin, whose registration can get flaky
  when the signing identity changes between builds. Minor; noted as a manual
  verification point.

**Notarization + Developer ID signing is explicitly out of scope here** but is
purely *additive* later: a real signature + a notarize/staple step in
`make bundle`. No Sparkle rework — same appcast, same EdDSA keys, same code.
Doing it later also retires the two friction points above. Mac App Store
distribution is likewise out of scope (it is a separate, stricter pipeline
requiring sandboxing and App Review, and would mean *no* in-app update UI at
all).

## Architecture & boundaries

This is an **app-shell + build-tooling** feature, not a `PagerCore` one.
Sparkle is a UI/side-effect concern, so it lives entirely in the `Pager`
executable target at the AppKit boundary — exactly like `SharingServiceMailComposer`
or `FirebaseClient`. `PagerCore` stays pure, AppKit-free, and gains nothing:
there is no pure decision worth unit-testing here. Version derivation is a
build-time Makefile concern; the update flow is delegated wholesale to Sparkle.

The views stay dumb (the testability rule is respected by there being no logic
to test, not by adding an untested seam): they render an `updateAvailable` flag
and call an `installUpdate()` action on a shared controller.

## Components

### 1. `UpdateController` (Pager app target)

A thin shell over Sparkle's `SPUUpdater`, owned by `AppDelegate`. It is the
single source of truth for update state, shared across all per-link UI.

- Imports `Sparkle` + AppKit, so it belongs in the app target, **not**
  `PagerCore`. It is a side-effect seam in the same spirit as the mail composer.
- Constructs/owns a Sparkle updater (via `SPUStandardUpdaterController` or a
  directly-constructed `SPUUpdater` + `SPUStandardUserDriver`), with
  `UpdateController` itself acting as the `SPUStandardUserDriverDelegate`.
- Conforms to `ObservableObject` and publishes:
  - `updateAvailable: Bool` — a background check found a pending update;
  - `availableVersionString: String?` — for display ("Update to 1.2.0");
  - `installUpdate()` — hands control back to Sparkle to download/verify/
    install/relaunch;
  - `checkForUpdates()` — the manual entry point (Settings button);
  - `automaticallyChecksForUpdates: Bool` — bound to the updater's own
    persisted setting.
- `AppDelegate` owns the single instance and injects it into every
  `LinkViewModel`/`PopoverView` and into `SettingsView`.

### 2. Gentle-reminder suppression (no modal popup)

Sparkle's **"gentle reminders"** support is what lets us replace the default
modal alert for background-found updates with our own non-blocking element:

- `UpdateController` returns `supportsGentleScheduledUpdateReminders = true`.
- When a **scheduled/background** check finds an update, the delegate suppresses
  Sparkle's standard alert and instead sets `updateAvailable = true` +
  `availableVersionString`. No window, no focus steal.
- The user acts on it through our own UI (below). Clicking it calls back into
  Sparkle, which proceeds with the normal download → EdDSA verify → install →
  relaunch sequence (a small progress indicator during that phase is fine and
  expected — the user opted in).
- **Manual checks are *not* suppressed.** When the user explicitly clicks
  "Check for Updates…" in Settings, Sparkle's standard UI (progress, "you're up
  to date", or the update prompt) is shown — explicit user-initiated actions
  warrant visible feedback. Gentle suppression applies only to the unsolicited
  background path.

### 3. The "Update now" affordance in `PopoverView`

- A small **"Update now"** clickable text element rendered in `PopoverView`
  alongside the existing close/menu controls.
- **Absent entirely when no update is pending** — zero footprint in the normal
  case; it appears only when `UpdateController.updateAvailable` is true.
- Clicking it calls `UpdateController.installUpdate()`.
- Because `PopoverView` is **per-link** (one `NSStatusItem` + `NSPopover` per
  link) but update state is **global**, every popover observes the one shared
  `UpdateController`, so the link shows up consistently in whichever popover the
  user opens.

### 4. Settings integration & the zero-links fallback

`SettingsView` (the one shared window) gains:

- a **"Check for Updates…"** button → `UpdateController.checkForUpdates()`
  (standard Sparkle UI);
- an **"Automatically check for updates"** toggle → bound to
  `automaticallyChecksForUpdates` (Sparkle persists this and the daily check
  interval in `UserDefaults` automatically);
- when an update is pending, the same area shows **"Update available — install"**
  → `installUpdate()`.

**Zero-links fallback:** with no links there is no popover to host the "Update
now" link, so the Settings window is the fallback surface (via the
"Update available — install" affordance above). The onboarding/AddPager flow is
deliberately **not** given an update affordance — someone mid-onboarding is not
the target.

### 5. `Info.plist` additions

- `SUFeedURL` = `https://july.dev/pager/appcast.xml` (served alongside the
  existing `Pager.zip`).
- `SUPublicEDKey` = the committed EdDSA **public** key (safe to commit).
- Sparkle's default scheduled-check behavior is enabled; the daily interval is
  Sparkle's standard.

### 6. Versioning (Makefile)

`make bundle` stops copying the static `Info.plist` verbatim and instead stamps
the version fields into the **bundled** plist at build time (leaving the source
`packaging/Info.plist` as a template; use `PlistBuddy`/`plutil`):

- `CFBundleShortVersionString` ← `git describe --tags`
  (e.g. `1.2.0`, or `1.2.0-5-gabc123` for untagged dev builds, so dev builds
  never masquerade as a release).
- `CFBundleVersion` ← `git rev-list --count HEAD` (monotonic — this is the
  field Sparkle compares to decide "newer").

Cutting a release is therefore one manual decision: tag the commit
(`git tag -a v1.2.0 -m "…"` + `git push origin v1.2.0`). Everything else is
derived.

### 7. Release flow — `make release`

A single target performs the whole release so the zip and appcast can never
drift apart (the classic "shipped a zip but forgot the feed" bug):

1. `make bundle` (with the new versioning + framework embedding, §8).
2. `make zip`.
3. `sign_update dist/Pager.zip` (Sparkle tool) → EdDSA signature.
4. Regenerate `dist/appcast.xml` with the new entry: version, build, download
   URL, signature, content length, and an optional one-line release note.
5. Copy **both** `Pager.zip` and `appcast.xml` into
   `/Users/jeroen/code/jpjagt/july.dev/public/pager/`.

The maintainer then commits + deploys july.dev as usual.

- **Release notes:** minimal — `make release` accepts an optional
  `NOTES="…"` that becomes the appcast entry's description. No CHANGELOG
  infrastructure for now.
- **EdDSA keys:** `generate_keys` is run **once**; it stores the **private**
  key in the macOS **Keychain** (never committed, never in the repo).
  `sign_update` reads it from the Keychain at release time, so **releases can
  only be cut from the machine holding that key**. The spec's setup step
  includes exporting a backup of the private key to a safe place (losing it
  means existing installs can no longer verify new updates).

### 8. Framework embedding (the main technical risk)

Sparkle is not header-only: it ships as `Sparkle.framework` containing helper
executables (`Autoupdate`, an updater app, XPC services). In a normal Xcode
project an "Embed Frameworks" build phase handles this, but `make bundle` is
hand-rolled and currently copies only a single executable + plist. We must
replicate the embed manually in `make bundle`:

- copy `Sparkle.framework` from the SPM build artifacts into
  `dist/Pager.app/Contents/Frameworks/`, including its nested helpers;
- ensure runtime linkage resolves (`@rpath`);
- **deep-codesign** the bundle (sign nested helpers/framework first, then the
  app), still ad-hoc (`codesign -s -`).

This is the fiddliest part and the most likely source of "works in `swift run`,
broken in the bundle" surprises. **Definition of done for the whole feature is a
real end-to-end update:** build N installed, build N+1 published to a (local or
real) appcast, and the running build N updating itself to N+1 via the "Update
now" affordance and relaunching.

## Testing & verification

- **No new `PagerCore` unit tests** — there is no pure logic to test; the update
  flow is entirely Sparkle's, behind an app-target seam.
- **Manual verification (the real bar):**
  1. `make bundle` stamps the expected `CFBundleShortVersionString` /
     `CFBundleVersion` from git.
  2. End-to-end self-update: a running bundle discovers, downloads, verifies,
     installs, and relaunches into a newer build via the non-modal "Update now"
     link.
  3. Background check surfaces the affordance **without** a modal popup; manual
     Settings check **does** show standard Sparkle feedback.
  4. `SMAppService` LaunchAtLogin still behaves across an update (the ad-hoc
     identity caveat).

## Out of scope

- Notarization + Developer ID signing (additive later, no rework; retires the
  first-install Gatekeeper friction and the ad-hoc-identity caveat).
- Mac App Store distribution.
- Rich release-notes / changelog infrastructure.
- Delta updates.
