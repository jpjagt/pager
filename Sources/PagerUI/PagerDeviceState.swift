import Foundation
import PagerCore

/// Everything `PagerDeviceView` needs to render one frame of the device — a
/// plain value type, no store/engine/controller access. This is what lets
/// `design-preview` construct any visual state as a literal and lets a later
/// task's thin adapter map live models onto these fields without the view
/// itself ever knowing about `LinkViewModel`/`UpdateController`.
public struct PagerDeviceState {
    /// Names match `AppearancePrefs.screenColor`/`caseColor`.
    public var screenColor: ScreenColor
    public var caseColor: CaseColor
    /// The draft/synced text. Empty while the pager holds an image instead
    /// (see `imageData`) — a pager holds text OR an image, never both.
    public var text: String
    /// Present only when the pager currently holds an image.
    public var imageData: Data?
    public var isWindowFocused: Bool
    public var isOffline: Bool
    /// `nil` — no update banner. Otherwise the version string to show
    /// ("update 1.4.0 available —").
    public var updateBannerVersion: String?
    /// URLs detected in `text`, one link banner rendered per entry.
    public var links: [URL]

    public init(
        screenColor: ScreenColor = .green,
        caseColor: CaseColor = .darkGrey,
        text: String = "",
        imageData: Data? = nil,
        isWindowFocused: Bool = true,
        isOffline: Bool = false,
        updateBannerVersion: String? = nil,
        links: [URL] = []
    ) {
        self.screenColor = screenColor
        self.caseColor = caseColor
        self.text = text
        self.imageData = imageData
        self.isWindowFocused = isWindowFocused
        self.isOffline = isOffline
        self.updateBannerVersion = updateBannerVersion
        self.links = links
    }
}

/// Callbacks out — the other half of the props-in/callbacks-out boundary.
/// All defaulted to no-ops so a preview/test can construct one supplying only
/// the handful it cares about.
public struct PagerDeviceActions {
    public var onTextChange: (String) -> Void
    /// Enter in the text field.
    public var onSubmit: () -> Void
    /// The send key.
    public var onSend: () -> Void
    /// The ✕ key.
    public var onClose: () -> Void
    /// The `C` key.
    public var onClear: () -> Void
    /// The `···` key.
    public var onMenu: () -> Void
    /// A tap on a detected-URL link banner.
    public var onOpenURL: (URL) -> Void
    /// "update now" in the update banner.
    public var onUpdateNow: () -> Void
    /// "hide" in the update banner.
    public var onHideUpdate: () -> Void

    public init(
        onTextChange: @escaping (String) -> Void = { _ in },
        onSubmit: @escaping () -> Void = {},
        onSend: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {},
        onClear: @escaping () -> Void = {},
        onMenu: @escaping () -> Void = {},
        onOpenURL: @escaping (URL) -> Void = { _ in },
        onUpdateNow: @escaping () -> Void = {},
        onHideUpdate: @escaping () -> Void = {}
    ) {
        self.onTextChange = onTextChange
        self.onSubmit = onSubmit
        self.onSend = onSend
        self.onClose = onClose
        self.onClear = onClear
        self.onMenu = onMenu
        self.onOpenURL = onOpenURL
        self.onUpdateNow = onUpdateNow
        self.onHideUpdate = onHideUpdate
    }
}
