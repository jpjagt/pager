import Foundation

/// Pure placement math for where a pager window appears the **first** time it
/// opens, before the user has ever dragged it. Once dragged, the persisted
/// `windowFrame` on `PagerLink` takes over and this function is no longer
/// consulted.
///
/// Anchors top-right of `visibleFrame` (inset by a sensible margin), then
/// steps down-left while the candidate overlaps an already-open pager. Since
/// every open pager's frame is known via `occupied`, this is exact overlap
/// avoidance, not blind index-based cascading.
///
/// No AppKit, no `NSScreen` — everything is computed relative to
/// `visibleFrame`'s own origin, which is not assumed to be `.zero` (it isn't,
/// on most multi-monitor setups). macOS screen coordinates are bottom-left
/// origin, so "top" is `maxY`.
public enum PagerWindowPlacement {
    /// Margin from the screen edge for the initial top-right anchor.
    public static let inset: CGFloat = 24
    /// Per-step offset while probing for a non-overlapping spot.
    public static let stepX: CGFloat = 32
    public static let stepY: CGFloat = 32
    /// Termination guard: a crowded screen must not spin forever.
    public static let maxSteps = 40

    public static func frame(size: CGSize, in visibleFrame: CGRect,
                              avoiding occupied: [CGRect]) -> CGRect {
        let anchor = topRight(size: size, in: visibleFrame, inset: inset)

        var candidate = anchor
        for _ in 0..<maxSteps {
            if !occupied.contains(where: { $0.intersects(candidate) }) {
                return candidate
            }
            candidate = candidate.offsetBy(dx: -stepX, dy: -stepY)
            if !fits(candidate, in: visibleFrame) {
                break
            }
        }

        // Avoidance failed (or the candidate escaped the screen). Fall back
        // to a clamped cascade that is guaranteed to stay fully on screen.
        // The cascade index comes from how many pagers are already open —
        // the only value that actually differs between two overflow windows.
        return fallback(size: size, in: visibleFrame, attempt: occupied.count)
    }

    /// Clamps a remembered device rect back inside `visibleFrame`, keeping it
    /// as close to where the user left it as the screen allows. The *whole*
    /// rect ends up inside: a pager parked near the bottom that later grows
    /// (an image lands) would otherwise push its key row off the screen edge,
    /// where it can be neither pressed nor dragged back.
    ///
    /// A rect too big to fit an axis can't be contained at all; it is pinned
    /// left/bottom, keeping the key row (`C`/`···`/`✕`/send, at the device's
    /// bottom) on screen and letting the overflow happen at the top.
    public static func clamp(_ rect: CGRect, in visibleFrame: CGRect) -> CGRect {
        let maxX = max(visibleFrame.maxX - rect.width, visibleFrame.minX)
        let minY = visibleFrame.minY
        let maxY = max(visibleFrame.maxY - rect.height, minY)
        return CGRect(
            x: min(max(rect.minX, visibleFrame.minX), maxX),
            y: min(max(rect.minY, minY), maxY),
            width: rect.width,
            height: rect.height
        )
    }

    /// Top-right anchor, inset from the screen edge, sized to fit even on a
    /// screen smaller than `size + inset`.
    private static func topRight(size: CGSize, in visibleFrame: CGRect, inset: CGFloat) -> CGRect {
        let width = min(size.width, visibleFrame.width)
        let height = min(size.height, visibleFrame.height)
        let x = min(visibleFrame.maxX - inset - width, visibleFrame.maxX - width)
        let y = min(visibleFrame.maxY - inset - height, visibleFrame.maxY - height)
        return CGRect(
            x: max(x, visibleFrame.minX),
            y: max(y, visibleFrame.minY),
            width: width,
            height: height
        )
    }

    /// Whether `candidate` lies entirely within `visibleFrame`.
    private static func fits(_ candidate: CGRect, in visibleFrame: CGRect) -> Bool {
        visibleFrame.contains(candidate)
    }

    /// A cascade down-left from the anchor, guaranteed to stay inside
    /// `visibleFrame`, used when the stepping search can't find (or steps off)
    /// a clear spot. `attempt` is the caller's occupancy count, so consecutive
    /// overflow windows land on consecutive slots instead of stacking on one
    /// anchor where only the topmost is clickable. The slot count is however
    /// many whole steps fit between the anchor and the screen's bottom-left
    /// corner; past that it wraps, since there is nowhere else to go.
    private static func fallback(size: CGSize, in visibleFrame: CGRect, attempt: Int) -> CGRect {
        let base = topRight(size: size, in: visibleFrame, inset: inset)
        let slotsX = Int((base.minX - visibleFrame.minX) / stepX)
        let slotsY = Int((base.minY - visibleFrame.minY) / stepY)
        let slotCount = max(min(slotsX, slotsY), 0) + 1
        let slot = abs(attempt) % slotCount

        let candidate = base.offsetBy(dx: -CGFloat(slot) * stepX, dy: -CGFloat(slot) * stepY)
        return clamp(candidate, in: visibleFrame)
    }
}
