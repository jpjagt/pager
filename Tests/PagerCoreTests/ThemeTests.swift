import XCTest
@testable import PagerCore

final class ThemeTests: XCTestCase {
    /// `#RRGGBB` — opaque hex only, no alpha (that's a view-layer decision).
    private func assertValidHex(_ value: String, _ field: String, file: StaticString = #filePath, line: UInt = #line) {
        let pattern = "^#[0-9A-Fa-f]{6}$"
        let matches = value.range(of: pattern, options: .regularExpression) != nil
        XCTAssertTrue(matches, "\(field) is not a valid #RRGGBB hex string: \(value)", file: file, line: line)
    }

    func testEveryScreenColorHasACompleteValidPalette() {
        for color in ScreenColor.allCases {
            let palette = color.palette
            assertValidHex(palette.backlight, "\(color).backlight")
            assertValidHex(palette.ink, "\(color).ink")
            assertValidHex(palette.glow, "\(color).glow")
            assertValidHex(palette.menuBarInkOnLight, "\(color).menuBarInkOnLight")
            assertValidHex(palette.menuBarInkOnDark, "\(color).menuBarInkOnDark")
        }
    }

    func testEveryCaseColorHasACompleteValidPalette() {
        for color in CaseColor.allCases {
            let palette = color.palette
            assertValidHex(palette.shellTop, "\(color).shellTop")
            assertValidHex(palette.shellBottom, "\(color).shellBottom")
            assertValidHex(palette.edgeHighlight, "\(color).edgeHighlight")
            assertValidHex(palette.edgeShadow, "\(color).edgeShadow")
            assertValidHex(palette.bezel, "\(color).bezel")
            assertValidHex(palette.keyTop, "\(color).keyTop")
            assertValidHex(palette.keyBottom, "\(color).keyBottom")
            assertValidHex(palette.keyEdge, "\(color).keyEdge")
            assertValidHex(palette.sendTop, "\(color).sendTop")
            assertValidHex(palette.sendBottom, "\(color).sendBottom")
            assertValidHex(palette.brandInk, "\(color).brandInk")
            assertValidHex(palette.brandHighlight, "\(color).brandHighlight")
        }
    }

    func testNextUnusedReturnsFirstUnusedInAllCasesOrder() {
        // First two allCases entries taken -> first unused is the third.
        let taken = Array(ScreenColor.allCases.prefix(2))
        XCTAssertEqual(ScreenColor.nextUnused(taken: taken), ScreenColor.allCases[2])
    }

    func testNextUnusedEmptyReturnsGreen() {
        XCTAssertEqual(ScreenColor.nextUnused(taken: []), .green)
    }

    func testNextUnusedIgnoresDuplicatesAndOrderWithinTaken() {
        // .green and .blue both taken (with a duplicate, and out of allCases order)
        // -> first unused in allCases order is whatever follows immediately after
        // the taken prefix, independent of how `taken` is ordered.
        let first = ScreenColor.allCases[0]
        let second = ScreenColor.allCases[1]
        let expected = ScreenColor.allCases[2]
        XCTAssertEqual(ScreenColor.nextUnused(taken: [second, first, second]), expected)
    }

    func testNextUnusedWrapsToGreenWhenAllSevenTaken() {
        XCTAssertEqual(ScreenColor.allCases.count, 7)
        XCTAssertEqual(ScreenColor.nextUnused(taken: ScreenColor.allCases), .green)
    }

    func testNextUnusedWrapsToGreenWhenAllTakenWithExtraDuplicates() {
        // Order/duplicates within `taken` must not matter once all cases are present.
        let taken = ScreenColor.allCases.reversed() + ScreenColor.allCases
        XCTAssertEqual(ScreenColor.nextUnused(taken: Array(taken)), .green)
    }
}
