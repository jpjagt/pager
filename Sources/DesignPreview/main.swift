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

struct Options {
    var caseColor: CaseColor = .darkGrey
    var screenColor: ScreenColor?
    var outPath: String = "./preview.png"
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
        default:
            fail("unknown argument '\(arg)'")
        }
    }
    return options
}

/// Placeholder content standing in for the LCD/keys that arrive in later
/// tasks — this task only proves the CASE renders and looks molded. A
/// near-full-frame black box (round 1's original placeholder) made the case
/// impossible to judge since it visually dominated the render; a thin
/// outline plus a small label proves the shell without competing with it.
/// The real LCD (not black) is Task 4's job.
struct PlaceholderContent: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
            .overlay(
                Text("LCD")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.28))
            )
            .aspectRatio(16.0 / 7.0, contentMode: .fit)
    }
}

/// Task 4's content: a lit `LCDPanel` with sample message text plus a
/// stacked pair of inverted-video `Banner`s (an offline notice above an
/// update prompt), so both new views are visible in one render. The two
/// banners are separated by `spacing: 1` — the "one LCD pixel" gap the task
/// brief calls for.
struct ScreenContent: View {
    let palette: ScreenPalette

    var body: some View {
        LCDPanel(palette: palette) {
            VStack(alignment: .leading, spacing: 6) {
                Text("dinner at 7?")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                Spacer(minLength: 0)
                VStack(spacing: 1) {
                    Banner(palette: palette, style: .plain("offline — retrying"))
                    Banner(
                        palette: palette,
                        style: .action([
                            Banner.Segment("update available —"),
                            Banner.Segment("update now") {},
                        ])
                    )
                }
            }
        }
        .aspectRatio(16.0 / 7.0, contentMode: .fit)
    }
}

let options = parseArguments(Array(CommandLine.arguments.dropFirst()))
let palette = options.caseColor.palette

// A pager is a landscape device: the real app renders it in a 360pt-wide
// window whose height follows content. 360×190pt (720×380px at scale 2) is
// the fixed reference size for this preview — round 1 of the visual gate
// found the previous 300×460 *portrait* frame was skewing every other
// judgement (bevel, corner radius, content proportions all read wrong on a
// rectangle turned the wrong way).
let preview = PagerShell(palette: palette) {
    if let screenColor = options.screenColor {
        ScreenContent(palette: screenColor.palette)
    } else {
        PlaceholderContent()
    }
}
.frame(width: 360, height: 190)

let pngData: Data? = MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: preview)
    renderer.scale = 2
    guard let nsImage = renderer.nsImage,
          let tiff = nsImage.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { return nil }
    return png
}

guard let pngData else { fail("failed to render preview image") }

do {
    try pngData.write(to: URL(fileURLWithPath: options.outPath))
} catch {
    fail("failed to write PNG to \(options.outPath): \(error)")
}

print("design-preview: wrote \(options.outPath)")
