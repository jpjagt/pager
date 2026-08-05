import SwiftUI
import PagerCore

/// The composed device: `PagerShell` (case + keys + wordmark) wrapping an
/// `LCDPanel` (screen) whose content is the fixed stack described in the
/// task brief — **props in, callbacks out, nothing else.** No
/// `LinkViewModel`, no `UpdateController`, no store access: `PagerDeviceAdapter`
/// (in the `Pager` target) is the thin adapter that maps live models onto
/// `PagerDeviceState`/`PagerDeviceActions`, which is what lets
/// `design-preview` render any state as a literal value.
///
/// Vertical order inside the LCD (fixed, do not reorder): offline banner
/// (pinned top) → text → image (if any) → one link banner per URL → update
/// banner (pinned bottom). "Pinned" falls out of plain `VStack` ordering —
/// there's no scrolling content here to pin against, just first/last child.
///
/// Width is fixed at 360; height is whatever the content naturally needs
/// (nothing in this view or the ones it composes imposes a fixed/aspect
/// height), so a growing message, an attached image, or a stack of banners
/// all grow the device — which is what `PagerWindow` measures via this
/// view's fitting size.
public struct PagerDeviceView: View {
    /// The LCD's usable content width: 360 (device) − 2× shell content inset
    /// (`PagerShell`'s default `cornerRadius` 18 × 0.55) − 2× `LCDPanel`'s
    /// own internal padding (10). Only used to size the image row; a few
    /// points of slack here just leaves the image narrower than the panel,
    /// never clipped or overflowing.
    private static let lcdContentWidth: CGFloat = 320
    private static let deviceWidth: CGFloat = 360

    private let state: PagerDeviceState
    private let actions: PagerDeviceActions

    public init(state: PagerDeviceState, actions: PagerDeviceActions = PagerDeviceActions()) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        PagerShell(
            palette: state.caseColor.palette,
            onClear: actions.onClear,
            onMenu: actions.onMenu,
            onClose: actions.onClose,
            onSend: actions.onSend
        ) {
            LCDPanel(palette: screenPalette) {
                screenContent
            }
        }
        .frame(width: Self.deviceWidth)
        // An unfocused window's backlight reads a touch duller — the same
        // cue a real inactive window gives, just applied to the LCD glow
        // rather than a whole-window dim.
        .opacity(state.isWindowFocused ? 1 : 0.88)
        .accessibilityIdentifier("pager-device")
    }

    @ViewBuilder
    private var screenContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.isOffline {
                Banner(palette: screenPalette, style: .plain("offline — retrying"))
                    .accessibilityIdentifier("offline-banner")
            }

            textField

            if let imageData = state.imageData {
                imageContent(imageData)
            }

            // Link banners and the update banner are the two kinds of chrome
            // that can land directly adjacent to each other (no text/image
            // row in between) — grouped in their own `spacing: 1` stack per
            // `Banner`'s doc: 1pt reads as a single dark LCD pixel between
            // two lit rows, so a run of banners reads as one continuous strip
            // of chrome rather than separate rows with the backlight showing
            // through the gaps. The outer `spacing: 6` (between this stack
            // and the text/image above it) is unaffected.
            if !state.links.isEmpty || state.updateBannerVersion != nil {
                VStack(spacing: 1) {
                    ForEach(Array(state.links.enumerated()), id: \.offset) { index, url in
                        Banner(
                            palette: screenPalette,
                            style: .action([
                                Banner.Segment(url.absoluteString,
                                               accessibilityIdentifier: "link-banner-\(index)") {
                                    actions.onOpenURL(url)
                                },
                            ])
                        )
                        .accessibilityIdentifier("link-banner")
                    }

                    if let version = state.updateBannerVersion {
                        Banner(
                            palette: screenPalette,
                            style: .action([
                                Banner.Segment("update \(version) available —"),
                                Banner.Segment("update now", accessibilityIdentifier: "update-banner-update-now") {
                                    actions.onUpdateNow()
                                },
                                Banner.Segment("·"),
                                Banner.Segment("hide", accessibilityIdentifier: "update-banner-hide") {
                                    actions.onHideUpdate()
                                },
                            ])
                        )
                        .accessibilityIdentifier("update-banner")
                    }
                }
            }
        }
    }

    /// The message field. Wraps (`axis: .vertical`) so a long message grows
    /// the device rather than scrolling off the edge of the LCD — but a
    /// vertical-axis `TextField` also swallows plain Return as a newline
    /// insertion instead of firing `onSubmit` (confirmed: this is standard
    /// SwiftUI behavior on macOS, not a bug). The zero-size, invisible
    /// `.defaultAction` button behind it reclaims plain Return for submit
    /// (leaving Option+Return free to insert an actual newline) — a documented
    /// workaround for exactly this multiline-TextField-onSubmit gap.
    private var textField: some View {
        TextField("type a message…", text: textBinding, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .tint(ink) // caret color — a blue system caret on a green LCD breaks the illusion
            .background(
                Button(action: actions.onSubmit) { EmptyView() }
                    .keyboardShortcut(.defaultAction)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            )
            .accessibilityIdentifier("pager-text-field")
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { state.text },
            set: { newValue in
                let max = EditorSession.maxLength // the invariant's home; never a literal here
                let capped = newValue.count > max ? String(newValue.prefix(max)) : newValue
                actions.onTextChange(capped)
            }
        )
    }

    /// The LCD shows the image small and downscaled; tapping it is how you see
    /// the real thing (Preview, or the page it came from). A `Button` rather
    /// than `onTapGesture` so the affordance is a real control — reachable by
    /// keyboard and VoiceOver, not just the mouse.
    @ViewBuilder
    private func imageContent(_ data: Data) -> some View {
        if let pixelSize = ImageCodec.pixelSize(of: data), let nsImage = NSImage(data: data) {
            let layout = ImageDisplayMath.containerLayout(
                imagePixelSize: pixelSize, containerWidth: Self.lcdContentWidth)
            Button(action: actions.onOpenImage) {
                ZStack {
                    Color.black.opacity(0.25)
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: layout.imageSize.width, height: layout.imageSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .frame(width: layout.containerSize.width, height: layout.containerSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .accessibilityIdentifier("pager-image")
            .accessibilityLabel("open image")
        }
    }

    private var screenPalette: ScreenPalette { state.screenColor.palette }

    private var ink: Color {
        Color(nsColor: TextUtil.color(fromHex: screenPalette.ink) ?? .black)
    }
}
