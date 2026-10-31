import Carbon
import Testing

@testable import Search

@Test func parsesModifiersInAnyOrder() throws {
    #expect(try KeyChord(parsing: "cmd+space") == KeyChord(.command, .space))
    #expect(try KeyChord(parsing: "shift+ctrl+opt+k") == KeyChord([.control, .option, .shift], .k))
    #expect(try KeyChord(parsing: "f5") == KeyChord([], .f5))
    #expect(try KeyChord(parsing: "cmd+leftbracket") == KeyChord(.command, .leftBracket))
}

@Test func parsesAnyCase() throws {
    #expect(try KeyChord(parsing: "Cmd+Space") == KeyChord(.command, .space))
    #expect(try KeyChord(parsing: "F13") == KeyChord([], .f13))
    #expect(try KeyChord(parsing: "CTRL+LeftBracket") == KeyChord(.control, .leftBracket))
}

@Test func takesShiftAloneOnlyWithAnFKey() throws {
    #expect(try KeyChord(parsing: "shift+f3") == KeyChord(.shift, .f3))
    #expect(try KeyChord(parsing: "shift+cmd+a") == KeyChord([.shift, .command], .a))
}

@Test(arguments: [
    ("", "it is empty"),
    ("cmd+", "it has no key after the last +"),
    ("cmd+foo", "\"foo\" isn't a key"),
    ("space", "it needs a modifier, as only F1 to F20 can be used alone"),
    ("hyper+k", "\"hyper\" isn't a modifier: they are ctrl, opt, shift and cmd"),
    ("cmd+Cmd+k", "it has cmd twice"),
    ("cmd+f21", "\"f21\" isn't a key"),
    (
        "shift+a",
        "shift alone would take the key from typing; only F1 to F20 can be used with shift alone"
    ),
    (
        "shift+space",
        "shift alone would take the key from typing; only F1 to F20 can be used with shift alone"
    ),
])
func refusesABadChord(text: String, reason: String) {
    #expect(throws: KeyChord.ParseError(reason: reason)) { try KeyChord(parsing: text) }
}

@Test func writesTheConfigSpellingBack() throws {
    for text in ["cmd+space", "ctrl+opt+shift+cmd+k", "f12", "opt+rightbracket", "ctrl+0"] {
        #expect(try KeyChord(parsing: text).text == text)
    }
    #expect(try KeyChord(parsing: "Cmd+Shift+K").text == "shift+cmd+k")
}

@Test func printsAsAMenuDoes() {
    #expect(KeyChord(.command, .space).description == "⌘Space")
    #expect(KeyChord([.command, .control, .option, .shift], .k).description == "⌃⌥⇧⌘K")
    #expect(KeyChord([], .f5).description == "F5")
    #expect(KeyChord(.option, .comma).description == "⌥,")
}

@Test func modifierMasksAreCarbons() {
    #expect(KeyChord.Modifiers.command.rawValue == UInt32(cmdKey))
    #expect(KeyChord.Modifiers.shift.rawValue == UInt32(shiftKey))
    #expect(KeyChord.Modifiers.option.rawValue == UInt32(optionKey))
    #expect(KeyChord.Modifiers.control.rawValue == UInt32(controlKey))
}

@Test func keyCodesAreCarbons() {
    let carbon: [KeyChord.Key: Int] = [
        .a: kVK_ANSI_A, .b: kVK_ANSI_B, .c: kVK_ANSI_C, .d: kVK_ANSI_D, .e: kVK_ANSI_E,
        .f: kVK_ANSI_F, .g: kVK_ANSI_G, .h: kVK_ANSI_H, .i: kVK_ANSI_I, .j: kVK_ANSI_J,
        .k: kVK_ANSI_K, .l: kVK_ANSI_L, .m: kVK_ANSI_M, .n: kVK_ANSI_N, .o: kVK_ANSI_O,
        .p: kVK_ANSI_P, .q: kVK_ANSI_Q, .r: kVK_ANSI_R, .s: kVK_ANSI_S, .t: kVK_ANSI_T,
        .u: kVK_ANSI_U, .v: kVK_ANSI_V, .w: kVK_ANSI_W, .x: kVK_ANSI_X, .y: kVK_ANSI_Y,
        .z: kVK_ANSI_Z, .digit0: kVK_ANSI_0, .digit1: kVK_ANSI_1, .digit2: kVK_ANSI_2,
        .digit3: kVK_ANSI_3, .digit4: kVK_ANSI_4, .digit5: kVK_ANSI_5, .digit6: kVK_ANSI_6,
        .digit7: kVK_ANSI_7, .digit8: kVK_ANSI_8, .digit9: kVK_ANSI_9, .space: kVK_Space,
        .return: kVK_Return, .tab: kVK_Tab, .escape: kVK_Escape, .f1: kVK_F1, .f2: kVK_F2,
        .f3: kVK_F3, .f4: kVK_F4, .f5: kVK_F5, .f6: kVK_F6, .f7: kVK_F7, .f8: kVK_F8,
        .f9: kVK_F9, .f10: kVK_F10, .f11: kVK_F11, .f12: kVK_F12, .f13: kVK_F13, .f14: kVK_F14,
        .f15: kVK_F15, .f16: kVK_F16, .f17: kVK_F17, .f18: kVK_F18, .f19: kVK_F19,
        .f20: kVK_F20, .comma: kVK_ANSI_Comma, .period: kVK_ANSI_Period,
        .slash: kVK_ANSI_Slash, .semicolon: kVK_ANSI_Semicolon, .quote: kVK_ANSI_Quote,
        .backslash: kVK_ANSI_Backslash, .grave: kVK_ANSI_Grave, .minus: kVK_ANSI_Minus,
        .equal: kVK_ANSI_Equal, .leftBracket: kVK_ANSI_LeftBracket,
        .rightBracket: kVK_ANSI_RightBracket,
    ]
    #expect(Set(carbon.keys) == Set(KeyChord.Key.allCases))
    for (key, code) in carbon {
        #expect(Int(key.code) == code, "\(key)")
    }
}
