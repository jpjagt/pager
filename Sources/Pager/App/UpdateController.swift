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

    /// Mirrors Sparkle's automatic-check pref. Stored + @Published so the
    /// onboarding/settings toggles re-render when flipped; writes through to
    /// the updater.
    @Published var automaticallyChecksForUpdates = true {
        didSet { updaterController?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    private var updaterController: SPUStandardUpdaterController!

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        // Reflect the persisted / Info.plist default (SUEnableAutomaticChecks).
        automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
    }

    /// Manual "Check for Updates…" — shows Sparkle's standard UI.
    func checkForUpdates() { updaterController.updater.checkForUpdates() }

    /// User tapped our "Update now" affordance. Re-presents the pending
    /// background-found update through Sparkle's standard flow (confirm →
    /// download → verify → install → relaunch). Same call as a manual check;
    /// Sparkle resurfaces the already-found update.
    func installUpdate() { updaterController.updater.checkForUpdates() }

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
