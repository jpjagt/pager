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
    private static let deviceWidth: CGFloat = 360

    /// The LCD's usable content width, derived from the traced screen rect
    /// rather than hard-coded: the design-space LCD width scaled to the device,
    /// less `LCDPanel`'s own internal padding on both sides.
    ///
    /// This has to track the trace. When it didn't, an over-wide image row
    /// pushed the whole device stack past its 360 frame, and the *top-left
    /// chrome* — close key and wordmark — slid off the case edge, which is a
    /// long way from where the wrong number was.
    private static let lcdContentWidth: CGFloat =
        PagerOutlines.lcd.width * (deviceWidth / PagerOutlines.designSize.width) - 2 * PagerOutlines.lcdContentPadding
    /// Shared by the message field and its hand-drawn placeholder, which have
    /// to lay out identically or the prompt sits off the typing line.
    private static let messageFont = Font.system(size: 14, weight: .medium, design: .monospaced)

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
        // cue a real inactive window gives. Desaturation rather than opacity:
        // a translucent device stops reading as a physical object, while a
        // slightly greyed one just looks powered-down.
        .saturation(state.isWindowFocused ? 1 : 0.9)
        // The device is a physical object with a lit, light-colored screen: it
        // looks the same on a dark-mode Mac as on a light-mode one. Every color
        // in here comes from a palette, so nothing *should* read the
        // environment — this pins the subtree to light anyway, so the day
        // something appearance-aware sneaks in (a system control, a `.primary`
        // default) it still resolves against the panel it is drawn on. The host
        // does the same on the AppKit side (`PagerWindow`), since AppKit-backed
        // controls like `TextField` don't take their colors from here.
        .environment(\.colorScheme, .light)
        .accessibilityIdentifier("pager-device")
    }

    @ViewBuilder
    private var screenContent: some View {
        contentStack
            // An *overlay*, never a branch in the stack: it paints over the
            // screen without taking part in layout, so the device keeps
            // whatever height its content already gave it. Swapping content
            // for a prompt instead would resize the window mid-drag and slide
            // the drop target out from under the cursor.
            .overlay { dropZone }
    }

    @ViewBuilder
    private var contentStack: some View {
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
                                Banner.Segment("update \(version) —"),
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

    /// The dashed drop zone shown while a droppable drag is over the device.
    /// Filled with the backlight so it hides the message underneath rather than
    /// letting the prompt overprint it — the LCD reads as cleared, but nothing
    /// below it has actually moved.
    @ViewBuilder
    private var dropZone: some View {
        if let kind = state.dropTarget {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: TextUtil.color(fromHex: screenPalette.backlight) ?? .white))
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(
                        ink.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Text(kind == .image ? "drop image…" : "drop text…")
                    .font(Self.messageFont)
                    .foregroundColor(ink.opacity(0.75))
            }
            .allowsHitTesting(false) // the drag is the window's business, not a control's
            .accessibilityIdentifier("drop-zone")
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
        TextField("", text: textBinding, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Self.messageFont)
            // Both explicit, both from the palette: the LCD is a lit panel, so
            // its ink can never come from an appearance-derived default.
            .foregroundColor(ink)
            .tint(ink) // caret color — a blue system caret on a green LCD breaks the illusion
            .overlay(alignment: .topLeading) { placeholder }
            .background(
                Button(action: actions.onSubmit) { EmptyView() }
                    .keyboardShortcut(.defaultAction)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            )
            .accessibilityIdentifier("pager-text-field")
    }

    /// The empty-field prompt, drawn by hand rather than passed to `TextField`.
    /// A `TextField`'s own placeholder is painted in the system placeholder
    /// color, which is appearance-derived — near-white on a dark-mode Mac,
    /// which washes out completely on the lit panel (the one thing in the
    /// device that measurably changed between light and dark before this).
    /// Faded `ink` instead: a dimmed version of what typing will produce.
    @ViewBuilder
    private var placeholder: some View {
        if state.text.isEmpty {
            Text("type a message…")
                .font(Self.messageFont)
                .foregroundColor(ink.opacity(0.45))
                .allowsHitTesting(false) // clicks belong to the field behind it
                .accessibilityHidden(true)
        }
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
