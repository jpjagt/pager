import Foundation

/// Does a key press insert characters, or does it do something else?
///
/// Pure so it can be tested without an `NSEvent`: the app layer passes the
/// event's `characters` and whether a non-shift modifier was held. Used by the
/// open-fresh edit, which has to decide *before* the key reaches the text field
/// whether it is the first character of a new message (wipe first) or the user
/// navigating/deleting inside the existing one (leave it alone).
public enum TypingKey {
    public static func isInsertion(characters: String?, hasNonShiftModifier: Bool) -> Bool {
        guard !hasNonShiftModifier, let scalar = characters?.unicodeScalars.first else { return false }
        switch scalar.value {
        // Return, Tab, Escape and friends.
        case 0x00...0x1F: return false
        // Forward/backward delete.
        case 0x7F: return false
        // Arrows, F-keys, Home/End/Page — AppKit reports these as private-use
        // scalars, which would otherwise read as perfectly ordinary characters.
        case 0xF700...0xF8FF: return false
        default: return true
        }
    }
}
