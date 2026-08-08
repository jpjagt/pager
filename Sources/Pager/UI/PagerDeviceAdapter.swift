import AppKit
import SwiftUI
import PagerCore
import PagerUI

/// The only place the live models meet the device chrome: maps
/// `LinkViewModel` + `UpdateController` + window focus onto
/// `PagerDeviceState`/`PagerDeviceActions`.
///
/// `PagerDeviceView` deliberately knows about none of those types (it lives in
/// `PagerUI` so `design-preview` can render it from literals), so this shim is
/// what keeps that boundary intact — it holds no logic of its own beyond the
/// mapping. The "hide the update banner" state itself (a dismissed version
/// string, so the banner returns for the *next* version) is owned and
/// persisted by `UpdateController`, not this view.
struct PagerDeviceAdapter: View {
    @ObservedObject var model: LinkViewModel
    @ObservedObject var updates: UpdateController
    @ObservedObject var focus: PagerWindowFocus
    @ObservedObject var previews: ImageURLPreviewLoader
    /// What is hovering over the device right now. View state, not model state:
    /// it exists only for the duration of a drag and nothing outside this view
    /// (or the drop zone it draws) has any use for it.
    @State private var dropTarget: DropTargetKind?

    init(model: LinkViewModel, updates: UpdateController, focus: PagerWindowFocus) {
        self.model = model
        self.updates = updates
        self.focus = focus
        self.previews = model.previewLoader
    }

    var body: some View {
        PagerDeviceView(state: state, actions: actions)
            .onDrop(of: PagerDropDelegate.acceptedTypes, delegate: PagerDropDelegate(
                onHover: { dropTarget = $0 },
                onPayload: { imageDatas, strings in
                    model.accept(imageDatas: imageDatas, strings: strings)
                }))
    }

    private var state: PagerDeviceState {
        PagerDeviceState(
            screenColor: model.appearance.screenColor,
            caseColor: model.appearance.caseColor,
            text: model.text,
            // The draft's own image, or — when the message is a link to one —
            // the lazily fetched preview of it.
            imageData: model.draftImage ?? previews.preview?.data,
            isWindowFocused: focus.isFocused,
            isOffline: model.showOfflineHint,
            updateBannerVersion: updates.bannerVersion,
            links: model.detectedURLs.map(\.url),
            dropTarget: dropTarget)
    }

    private var actions: PagerDeviceActions {
        let previewURL = previews.preview?.url
        return PagerDeviceActions(
            onTextChange: { model.setText($0) },
            onSubmit: { model.submit() },
            onSend: { model.submit() },
            onClose: { model.dismiss() },
            onClear: { model.clear() },
            onMenu: { model.onOpenMenu?() },
            onOpenURL: { NSWorkspace.shared.open($0) },
            // The image on screen is either the draft (open the file itself in
            // Preview) or a preview fetched for a link in the message (open the
            // page it came from) — same two destinations the popover had.
            onOpenImage: {
                if model.draftImage != nil {
                    model.openDraftImage()
                } else if let previewURL {
                    NSWorkspace.shared.open(previewURL)
                }
            },
            onUpdateNow: {
                // Let the window go before Sparkle's own window arrives.
                model.onRequestClose?()
                updates.installUpdate()
            },
            onHideUpdate: { updates.dismissUpdateBanner() })
    }
}
