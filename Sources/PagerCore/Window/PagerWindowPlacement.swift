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
    /// Fallback cascade wraps after this many attempts, to keep the clamped
    /// candidate from marching off the (clamped) right/bottom edge.
    private static let fallbackCascadeCount = 5

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
        return fallback(size: size, in: visibleFrame)
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

    /// A clamped cascade guaranteed to stay inside `visibleFrame`, used when
    /// the stepping search can't find (or steps off) a clear spot.
    private static func fallback(size: CGSize, in visibleFrame: CGRect) -> CGRect {
        let base = topRight(size: size, in: visibleFrame, inset: inset)
        let attempt = maxSteps % fallbackCascadeCount
        let dx = CGFloat(attempt) * stepX
        let dy = CGFloat(attempt) * stepY

        let width = base.width
        let height = base.height
        let maxDX = max(visibleFrame.width - width, 0)
        let maxDY = max(visibleFrame.height - height, 0)

        let x = base.minX - min(dx, maxDX)
        let y = base.minY - min(dy, maxDY)

        return CGRect(
            x: min(max(x, visibleFrame.minX), visibleFrame.maxX - width),
            y: min(max(y, visibleFrame.minY), visibleFrame.maxY - height),
            width: width,
            height: height
        )
    }
}
