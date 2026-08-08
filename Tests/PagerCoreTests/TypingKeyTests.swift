import XCTest
@testable import PagerCore

/// The decision that stands between "you opened a pager and started typing a
/// new message" and "you're editing the one that's there". The scalars come
/// from `NSEvent.characters`, which reports arrows and F-keys as private-use
/// characters — the case most likely to be got wrong.
final class TypingKeyTests: XCTestCase {
    func testOrdinaryCharactersInsert() {
        XCTAssertTrue(TypingKey.isInsertion(characters: "a", hasNonShiftModifier: false))
        XCTAssertTrue(TypingKey.isInsertion(characters: "A", hasNonShiftModifier: false))
        XCTAssertTrue(TypingKey.isInsertion(characters: " ", hasNonShiftModifier: false))
        XCTAssertTrue(TypingKey.isInsertion(characters: "é", hasNonShiftModifier: false))
        XCTAssertTrue(TypingKey.isInsertion(characters: "😀", hasNonShiftModifier: false))
        XCTAssertTrue(TypingKey.isInsertion(characters: "7", hasNonShiftModifier: false))
    }

    func testReturnTabAndEscapeDoNotInsert() {
        XCTAssertFalse(TypingKey.isInsertion(characters: "\r", hasNonShiftModifier: false))
        XCTAssertFalse(TypingKey.isInsertion(characters: "\n", hasNonShiftModifier: false))
        XCTAssertFalse(TypingKey.isInsertion(characters: "\t", hasNonShiftModifier: false))
        XCTAssertFalse(TypingKey.isInsertion(characters: "\u{1B}", hasNonShiftModifier: false))
    }

    func testDeleteDoesNotInsert() {
        XCTAssertFalse(TypingKey.isInsertion(characters: "\u{7F}", hasNonShiftModifier: false))
    }

    func testArrowsAndFunctionKeysDoNotInsert() {
        for scalar in [0xF700, 0xF701, 0xF702, 0xF703, 0xF704, 0xF729, 0xF72B] {
            let character = String(UnicodeScalar(UInt32(scalar))!)
            XCTAssertFalse(TypingKey.isInsertion(characters: character, hasNonShiftModifier: false),
                           "U+\(String(scalar, radix: 16)) is a navigation key, not a character")
        }
    }

    func testShortcutsDoNotInsert() {
        XCTAssertFalse(TypingKey.isInsertion(characters: "a", hasNonShiftModifier: true),
                       "⌘A/⌥A and friends are commands, not the start of a message")
    }

    func testShiftAloneStillInserts() {
        XCTAssertTrue(TypingKey.isInsertion(characters: "!", hasNonShiftModifier: false))
    }

    func testNoCharactersDoesNotInsert() {
        XCTAssertFalse(TypingKey.isInsertion(characters: nil, hasNonShiftModifier: false))
        XCTAssertFalse(TypingKey.isInsertion(characters: "", hasNonShiftModifier: false))
    }
}
