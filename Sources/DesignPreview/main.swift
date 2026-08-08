import AppKit
import SwiftUI
import PagerCore
import PagerUI

// DEV-ONLY CLI: renders `PagerUI` device views to a PNG so chrome changes can
// be verified by looking at an image instead of running the full app. Never
// shipped — see Makefile's `bundle` target, which does not reference this
// binary.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("design-preview: \(message)\n".utf8))
    exit(1)
}

let knownStates = ["empty", "long", "image", "offline", "update", "drop", "drop-long"]

struct Options {
    var caseColor: CaseColor = .darkGrey
    var screenColor: ScreenColor = .green
    var outPath: String = "./preview.png"
    var pressedKey: PagerKeyRow.Key?
    var sheet = false
    var stateName: String?
    /// Supersampling factor for the PNG. The view still lays out at its
    /// natural point size; only the bitmap is denser, so curves are re-drawn
    /// at the higher resolution instead of being upscaled. Exists so key
    /// silhouettes can be inspected for cusps, which are invisible at 1x.
    var scale: CGFloat = 1
}

func parseArguments(_ arguments: [String]) -> Options {
    var options = Options()
    var iterator = arguments.makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--case":
            guard let value = iterator.next() else { fail("--case requires a value") }
            guard let color = CaseColor(rawValue: value) else {
                let known = CaseColor.allCases.map(\.rawValue).joined(separator: ", ")
                fail("unknown case color '\(value)' — expected one of: \(known)")
            }
            options.caseColor = color
        case "--screen":
            guard let value = iterator.next() else { fail("--screen requires a value") }
            guard let color = ScreenColor(rawValue: value) else {
                let known = ScreenColor.allCases.map(\.rawValue).joined(separator: ", ")
                fail("unknown screen color '\(value)' — expected one of: \(known)")
            }
            options.screenColor = color
        case "--out":
            guard let value = iterator.next() else { fail("--out requires a value") }
            options.outPath = value
        case "--pressed":
            guard let value = iterator.next() else { fail("--pressed requires a value") }
            switch value {
            case "clear": options.pressedKey = .clear
            case "menu": options.pressedKey = .menu
            case "close": options.pressedKey = .close
            case "send": options.pressedKey = .send
            default: fail("unknown key '\(value)' — expected one of: clear, menu, close, send")
            }
        case "--scale":
            guard let value = iterator.next(), let scale = Double(value), scale > 0, scale <= 8 else {
                fail("--scale requires a number in (0, 8]")
            }
            options.scale = CGFloat(scale)
        case "--sheet":
            options.sheet = true
        case "--state":
            guard let value = iterator.next() else { fail("--state requires a value") }
            guard knownStates.contains(value) else {
                fail("unknown state '\(value)' — expected one of: \(knownStates.joined(separator: ", "))")
            }
            options.stateName = value
        default:
            fail("unknown argument '\(arg)'")
        }
    }
    return options
}

// MARK: - Synthetic sample data

/// A small synthetic image built entirely in code (a gradient square with a
/// label) so the `image` state never depends on an external file.
func syntheticImageData() -> Data {
    let size = CGSize(width: 480, height: 320)
    let image = NSImage(size: size)
    image.lockFocus()
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.35, green: 0.55, blue: 0.95, alpha: 1),
        NSColor(srgbRed: 0.85, green: 0.35, blue: 0.55, alpha: 1),
    ])
    gradient?.draw(in: NSRect(origin: .zero, size: size), angle: 45)
    let text = "sample.jpg" as NSString
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 28, weight: .bold),
        .foregroundColor: NSColor.white,
    ]
    let textSize = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
              withAttributes: attrs)
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { fail("failed to synthesize sample image") }
    return png
}

/// Builds the `PagerDeviceState` for one of the named states the brief calls
/// out as easy to get wrong.
func deviceState(forNamedState name: String, caseColor: CaseColor, screenColor: ScreenColor) -> PagerDeviceState {
    switch name {
    case "empty":
        return PagerDeviceState(screenColor: screenColor, caseColor: caseColor)
    case "long":
        return PagerDeviceState(
            screenColor: screenColor, caseColor: caseColor,
            text: "hey, are we still on for dinner at 7? I was thinking we could try that new ramen "
                + "place downtown, the one everyone's been talking about — let me know if that works "
                + "or if you'd rather do something else entirely, no pressure either way!")
    case "image":
        return PagerDeviceState(screenColor: screenColor, caseColor: caseColor, imageData: syntheticImageData())
    case "offline":
        return PagerDeviceState(screenColor: screenColor, caseColor: caseColor, text: "dinner at 7?", isOffline: true)
    case "update":
        return PagerDeviceState(
            screenColor: screenColor, caseColor: caseColor, text: "dinner at 7?",
            updateBannerVersion: "1.4.0")
    // The two drop states exist to be compared against `empty`/`long` at the
    // same palette: the drop zone is an overlay, so the device must come out
    // exactly the same height with and without it. A drag that resized the
    // pager would move the drop target out from under the cursor.
    case "drop":
        return PagerDeviceState(screenColor: screenColor, caseColor: caseColor, dropTarget: .image)
    case "drop-long":
        var state = deviceState(forNamedState: "long", caseColor: caseColor, screenColor: screenColor)
        state.dropTarget = .image
        return state
    default:
        fail("unknown state '\(name)'")
    }
}

// MARK: - Rendering

/// Renders via a real (invisible) `NSWindow` + `NSHostingView`, not
/// `ImageRenderer`. `ImageRenderer` cannot capture `TextField` at all — with
/// no real window/responder chain behind it, AppKit draws its generic
/// "content unavailable" glyph (a yellow bar with a red do-not-enter symbol)
/// in the control's place instead of the actual text. Hosting the view in a
/// real (never-shown) window and grabbing the bitmap via `cacheDisplay(in:to:)`
/// gives `NSTextField` a real backing store to lay out into, so the field
/// renders its real text/placeholder/font like every other view.
///
/// Returns an `NSImage` (not yet PNG-encoded) so the contact sheet can
/// composite many of these together before a single final encode.
func renderNSImage(_ view: some View, scale: CGFloat = 1) -> NSImage {
    MainActor.assumeIsolated {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 2000, height: 2000),
            styleMask: [.borderless], backing: .buffered, defer: false)
        hosting.frame = NSRect(x: 0, y: 0, width: 2000, height: 2000)
        window.contentView = hosting
        window.setIsVisible(false)
        hosting.layoutSubtreeIfNeeded()

        let fitting = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: fitting)
        window.setContentSize(fitting)
        hosting.layoutSubtreeIfNeeded()

        // A hand-built rep whose pixel dimensions are `scale`× its point size
        // makes `cacheDisplay` re-draw the view's vector content into the
        // denser bitmap, rather than upscaling a 1x raster.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((hosting.bounds.width * scale).rounded()),
            pixelsHigh: Int((hosting.bounds.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else {
            fail("failed to create bitmap rep for preview image")
        }
        rep.size = hosting.bounds.size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = NSImage(size: hosting.bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

func pngData(_ image: NSImage) -> Data {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { fail("failed to encode preview image as PNG") }
    return png
}

func renderPNG(_ view: some View, scale: CGFloat = 1) -> Data {
    pngData(renderNSImage(view, scale: scale))
}

func write(_ data: Data, to path: String) {
    do {
        try data.write(to: URL(fileURLWithPath: path))
    } catch {
        fail("failed to write PNG to \(path): \(error)")
    }
    print("design-preview: wrote \(path)")
}

/// One labelled cell in the contact sheet: a caption above the rendered
/// device, both on a plain light background so the case/screen colors read
/// against a neutral surface rather than each other.
struct SheetCell: View {
    let label: String
    let state: PagerDeviceState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.black.opacity(0.75))
            PagerDeviceView(state: state)
        }
    }
}

/// Every screen color × case color (7 × 2 = 14) plus each named state, one
/// PNG for the whole grid.
///
/// Each labelled cell is rendered to its own `NSImage` **independently**
/// (`renderNSImage`, small tree) and then composited onto one big canvas by
/// hand — deliberately NOT one giant SwiftUI tree of 19 nested devices fed to
/// a single `NSHostingView`. A first attempt did exactly that and it silently
/// mis-measured: `NSHostingView.fittingSize` under-reported the height of the
/// `long`-state cell's wrapping `TextField` once enough sibling content
/// (five rows, 19 devices, most with their own `TextField`) was in the same
/// tree, clipping it to ~3 lines instead of the 7 its content needs — even
/// though that exact cell measures correctly in isolation. Manual compositing
/// sidesteps the whole question: every cell is a small tree of the kind
/// already proven correct by the per-state renders, so there is nothing left
/// for a large-tree measurement bug to get wrong.
func renderContactSheet() -> Data {
    let colorCells: [(String, PagerDeviceState)] = CaseColor.allCases.flatMap { caseColor in
        ScreenColor.allCases.map { screenColor in
            ("\(caseColor.rawValue) / \(screenColor.rawValue)",
             PagerDeviceState(screenColor: screenColor, caseColor: caseColor, text: "dinner at 7?"))
        }
    }
    let stateCells: [(String, PagerDeviceState)] = knownStates.map { name in
        ("state: \(name)", deviceState(forNamedState: name, caseColor: .darkGrey, screenColor: .green))
    }
    let cells = colorCells + stateCells

    let columns = 4
    let padding: CGFloat = 28
    let gutter: CGFloat = 28
    let titleHeight: CGFloat = 30

    let cellImages = cells.map { label, state in renderNSImage(SheetCell(label: label, state: state)) }
    let rows = stride(from: 0, to: cellImages.count, by: columns).map {
        Array(cellImages[$0..<min($0 + columns, cellImages.count)])
    }

    let columnWidth = cellImages.map(\.size.width).max() ?? 360
    let rowHeights = rows.map { row in row.map(\.size.height).max() ?? 0 }
    let canvasWidth = padding * 2 + CGFloat(columns) * columnWidth + CGFloat(columns - 1) * gutter
    let canvasHeight = padding * 2 + titleHeight + rowHeights.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * gutter

    let canvas = NSImage(size: NSSize(width: canvasWidth, height: canvasHeight))
    canvas.lockFocus()
    NSColor(white: 0.92, alpha: 1).setFill()
    NSRect(origin: .zero, size: canvas.size).fill()

    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 16, weight: .bold),
        .foregroundColor: NSColor.black,
    ]
    ("pager — skeuomorphic contact sheet" as NSString).draw(
        at: NSPoint(x: padding, y: canvasHeight - padding - titleHeight + 6), withAttributes: titleAttrs)

    // NSImage drawing is bottom-up (Quartz convention); walk rows top-to-bottom
    // by tracking a descending `y` cursor rather than fighting the coordinate
    // system. Cells are top-aligned within their row (matching `HStack(alignment:
    // .top)`): each cell's own top sits at `rowTopY`, so only the tallest cell in
    // the row reaches the row's bottom edge — shorter cells (e.g. "state: empty"
    // sharing a row with "state: long") leave blank space below them, not above.
    var y = canvasHeight - padding - titleHeight
    for (row, rowHeight) in zip(rows, rowHeights) {
        let rowTopY = y
        var x = padding
        for cellImage in row {
            let cellY = rowTopY - cellImage.size.height
            cellImage.draw(in: NSRect(x: x, y: cellY, width: cellImage.size.width, height: cellImage.size.height))
            x += columnWidth + gutter
        }
        y = rowTopY - rowHeight - gutter
    }

    canvas.unlockFocus()
    return pngData(canvas)
}

// MARK: - Entry point

let options = parseArguments(Array(CommandLine.arguments.dropFirst()))

if options.sheet {
    write(renderContactSheet(), to: options.outPath)
} else if let stateName = options.stateName {
    let state = deviceState(forNamedState: stateName, caseColor: options.caseColor, screenColor: options.screenColor)
    write(renderPNG(PagerDeviceView(state: state), scale: options.scale), to: options.outPath)
} else if let pressedKey = options.pressedKey {
    // Keys-focused debug render (predates PagerDeviceView, still useful for
    // judging a single key's pressed look in isolation) — bypasses
    // PagerDeviceView since forcing one key's pressed state isn't part of its
    // props/callbacks surface.
    let preview = PagerShell(palette: options.caseColor.palette, pressedKey: pressedKey) {
        LCDPanel(palette: options.screenColor.palette) {
            Text("dinner at 7?")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
        }
    }
    .frame(width: 360)
    write(renderPNG(preview, scale: options.scale), to: options.outPath)
} else {
    let state = PagerDeviceState(screenColor: options.screenColor, caseColor: options.caseColor, text: "dinner at 7?")
    write(renderPNG(PagerDeviceView(state: state), scale: options.scale), to: options.outPath)
}
