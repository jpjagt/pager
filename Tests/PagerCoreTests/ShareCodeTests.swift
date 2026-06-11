import XCTest
@testable import PagerCore

final class ShareCodeTests: XCTestCase {
    func testGenerateProducesValidParseableCode() {
        let code = ShareCode.generate()
        XCTAssertEqual(code.entropy.count, 14)
        XCTAssertEqual(code.full.count, 16)
        XCTAssertEqual(ShareCode.parse(code.display), code)
        XCTAssertEqual(ShareCode.parse(code.full), code)
    }

    func testGenerateUsesAlphabetOnly() {
        let code = ShareCode.generate()
        XCTAssertTrue(code.full.allSatisfy { ShareCode.alphabet.contains($0) })
    }

    func testDisplayGroupsOfFour() {
        let code = ShareCode(entropy: "00000000000000")
        let display = code.display
        XCTAssertEqual(display.count, 19) // 16 chars + 3 hyphens
        XCTAssertEqual(display.split(separator: "-").map(\.count), [4, 4, 4, 4])
    }

    func testChecksumIsDeterministic() {
        // fixed vector: checksum of all-zeros entropy must be stable across runs
        let a = ShareCode(entropy: "00000000000000").full
        let b = ShareCode(entropy: "00000000000000").full
        XCTAssertEqual(a, b)
        XCTAssertEqual(String(a.suffix(2)), ShareCode.checksum(for: "00000000000000"))
        XCTAssertEqual(ShareCode.checksum(for: "00000000000000"), "5S")
    }

    func testParseIsCaseAndHyphenInsensitive() {
        let code = ShareCode.generate()
        let messy = code.display.lowercased().replacingOccurrences(of: "-", with: " ")
        XCTAssertEqual(ShareCode.parse(messy), code)
    }

    func testParseAppliesCrockfordAliases() {
        let code = ShareCode(entropy: "01010101010101")
        // replace 0→O and 1→l in the display; parse must normalize them back
        let aliased = code.display.replacingOccurrences(of: "0", with: "O")
                                  .replacingOccurrences(of: "1", with: "l")
        XCTAssertEqual(ShareCode.parse(aliased), code)
    }

    func testParseRejectsBadChecksum() {
        let code = ShareCode.generate()
        var chars = Array(code.full)
        let last = chars[15]
        chars[15] = (last == "0") ? "1" : "0"
        XCTAssertNil(ShareCode.parse(String(chars)))
    }

    func testParseRejectsWrongLengthAndBadChars() {
        XCTAssertNil(ShareCode.parse("SHORT"))
        XCTAssertNil(ShareCode.parse(String(repeating: "U", count: 16))) // U not in alphabet
        XCTAssertNil(ShareCode.parse(""))
    }
}
