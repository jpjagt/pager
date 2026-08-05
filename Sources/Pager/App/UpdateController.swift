import AppKit
import Sparkle

/// Thin shell over Sparkle's updater — the only code that touches Sparkle.
/// Owns the single updater instance, suppresses Sparkle's first-launch
/// permission prompt (we offer the choice in onboarding instead), suppresses
/// the modal alert for background-found updates (gentle reminders), and
/// publishes update state to the UI. Sparkle invokes its delegates on the main
/// thread, and AppDelegate constructs this on the main thread, so @Published
/// mutations are main-thread safe without extra hops.
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate,
    SPUStandardUserDriverDelegate {
    /// True once a *background* check has found an update (manual checks keep
    /// Sparkle's standard UI and do not set this).
    @Published private(set) var updateAvailable = false
    @Published private(set) var availableVersion: String?

    /// The version string the user last dismissed via the LCD banner's "hide",
    /// persisted app-wide in `UserDefaults` (not a per-window/session flag) so
    /// it survives relaunch. Deliberately a *version string*, not a bool —
    /// storing a bool would hide the banner forever; comparing versions means
    /// the next update still gets its own banner.
    @Published private(set) var dismissedVersion: String?

    /// The banner should show exactly when a background check found an update
    /// that isn't the one already dismissed.
    var bannerVersion: String? {
        guard updateAvailable, let availableVersion, availableVersion != dismissedVersion else { return nil }
        return availableVersion
    }

    /// User tapped "hide" on the LCD's update banner.
    func dismissUpdateBanner() {
        dismissedVersion = availableVersion
        defaults.set(availableVersion, forKey: Self.dismissedVersionKey)
    }

    /// Mirrors Sparkle's automatic-check pref. Stored + @Published so the
    /// onboarding/settings toggles re-render when flipped; writes through to
    /// the updater.
    @Published var automaticallyChecksForUpdates = true {
        didSet { updaterController?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    private static let dismissedVersionKey = "PagerDismissedUpdateVersion"

    private let defaults: UserDefaults
    private var updaterController: SPUStandardUpdaterController!

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.dismissedVersion = defaults.string(forKey: Self.dismissedVersionKey)
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        // Reflect the persisted / Info.plist default (SUEnableAutomaticChecks).
        automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
    }

    /// Manual "Check for Updates…" — shows Sparkle's standard UI.
    func checkForUpdates() { presentUpdateUI() }

    /// User tapped our "Update now" affordance. Re-presents the pending
    /// background-found update through Sparkle's standard flow (confirm →
    /// download → verify → install → relaunch). Same call as a manual check;
    /// Sparkle resurfaces the already-found update.
    func installUpdate() { presentUpdateUI() }

    /// Both entry points fire from a popover or menu that is still dismissing,
    /// and presenting a window mid-dismissal is what drops it behind other
    /// apps — so hop to the next runloop turn first. Activating before handing
    /// off also matters: for a background app Sparkle deliberately orders the
    /// update window to the back, and only force-activates when `!NSApp.isActive`
    /// (`SPUStandardUserDriver.setUpActiveUpdateAlertForScheduledUpdate`).
    /// Being active already puts us on its foreground path.
    private func presentUpdateUI() {
        DispatchQueue.main.async { [weak self] in
            NSApp.activateForWindow()
            self?.updaterController.updater.checkForUpdates()
        }
    }

    // MARK: SPUUpdaterDelegate

    /// Suppress Sparkle's first-launch "check automatically?" dialog — we ask
    /// in onboarding instead, so the choice lives with Launch at Login.
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    // MARK: SPUStandardUserDriverDelegate — gentle reminders

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false // we surface our own non-modal indicator instead of Sparkle's alert
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState) {
        guard !state.userInitiated else { return } // manual checks keep standard UI
        updateAvailable = true
        availableVersion = update.displayVersionString
    }
}
