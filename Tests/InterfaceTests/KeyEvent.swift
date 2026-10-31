import AppKit
import Testing

/// A key event as AppKit builds it for a real key press. `characters` defaults to
/// `ignoringModifiers`.
@MainActor
func keyEvent(
    _ ignoringModifiers: String, characters: String? = nil, modifiers: NSEvent.ModifierFlags = [],
    keyCode: UInt16 = 0
) throws -> NSEvent {
    try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters ?? ignoringModifiers,
            charactersIgnoringModifiers: ignoringModifiers, isARepeat: false, keyCode: keyCode))
}

/// The character NSEvent uses for a function key such as `NSDownArrowFunctionKey`.
func functionKey(_ code: Int) -> String {
    String(Character(Unicode.Scalar(UInt32(code))!))
}

/// Arrow events carry these flags along with the modifiers held.
let arrowFlags: NSEvent.ModifierFlags = [.numericPad, .function]
