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
/// tasks — this task only proves the case renders and looks molded.
struct PlaceholderContent: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.black.opacity(0.82))
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
    }
}

let options = parseArguments(Array(CommandLine.arguments.dropFirst()))
let palette = options.caseColor.palette

let preview = PagerShell(palette: palette) {
    PlaceholderContent()
}
.frame(width: 300, height: 460)

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
