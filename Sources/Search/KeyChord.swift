/// A global shortcut: modifiers and one key, as the config file's `hotkey` spells it
/// ("cmd+space") and as Carbon's `RegisterEventHotKey` takes it, in plain integers so Search
/// needs no Carbon import.
public struct KeyChord: Sendable, Equatable, CustomStringConvertible {
    /// The modifier keys held. The raw values are Carbon's masks (`cmdKey`, `controlKey`,
    /// `optionKey`, `shiftKey`), so `rawValue` is what `RegisterEventHotKey` takes.
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let command = Modifiers(rawValue: 1 << 8)
        public static let shift = Modifiers(rawValue: 1 << 9)
        public static let option = Modifiers(rawValue: 1 << 11)
        public static let control = Modifiers(rawValue: 1 << 12)

        /// Each modifier with its name in the config file and its symbol, in the order macOS
        /// menus draw them, which is also the order the config file writes them in.
        static let named: [(modifier: Modifiers, name: String, symbol: String)] = [
            (.control, "ctrl", "⌃"), (.option, "opt", "⌥"), (.shift, "shift", "⇧"),
            (.command, "cmd", "⌘"),
        ]
    }

    /// A key a chord can end with. The raw value is its name in the config file.
    public enum Key: String, Sendable, CaseIterable {
        case a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z
        case digit0 = "0"
        case digit1 = "1"
        case digit2 = "2"
        case digit3 = "3"
        case digit4 = "4"
        case digit5 = "5"
        case digit6 = "6"
        case digit7 = "7"
        case digit8 = "8"
        case digit9 = "9"
        case space, `return`, tab, escape
        case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18
        case f19, f20
        case comma, period, slash, semicolon, quote, backslash, grave, minus, equal
        case leftBracket = "leftbracket"
        case rightBracket = "rightbracket"

        /// The key's virtual key code, Carbon's `kVK_` value for it, which names a key by its
        /// place on an ANSI keyboard.
        public var code: UInt16 {
            switch self {
            case .a: 0x00
            case .s: 0x01
            case .d: 0x02
            case .f: 0x03
            case .h: 0x04
            case .g: 0x05
            case .z: 0x06
            case .x: 0x07
            case .c: 0x08
            case .v: 0x09
            case .b: 0x0B
            case .q: 0x0C
            case .w: 0x0D
            case .e: 0x0E
            case .r: 0x0F
            case .y: 0x10
            case .t: 0x11
            case .digit1: 0x12
            case .digit2: 0x13
            case .digit3: 0x14
            case .digit4: 0x15
            case .digit6: 0x16
            case .digit5: 0x17
            case .equal: 0x18
            case .digit9: 0x19
            case .digit7: 0x1A
            case .minus: 0x1B
            case .digit8: 0x1C
            case .digit0: 0x1D
            case .rightBracket: 0x1E
            case .o: 0x1F
            case .u: 0x20
            case .leftBracket: 0x21
            case .i: 0x22
            case .p: 0x23
            case .return: 0x24
            case .l: 0x25
            case .j: 0x26
            case .quote: 0x27
            case .k: 0x28
            case .semicolon: 0x29
            case .backslash: 0x2A
            case .comma: 0x2B
            case .slash: 0x2C
            case .n: 0x2D
            case .m: 0x2E
            case .period: 0x2F
            case .tab: 0x30
            case .space: 0x31
            case .grave: 0x32
            case .escape: 0x35
            case .f17: 0x40
            case .f18: 0x4F
            case .f19: 0x50
            case .f20: 0x5A
            case .f5: 0x60
            case .f6: 0x61
            case .f7: 0x62
            case .f3: 0x63
            case .f8: 0x64
            case .f9: 0x65
            case .f11: 0x67
            case .f13: 0x69
            case .f16: 0x6A
            case .f14: 0x6B
            case .f10: 0x6D
            case .f12: 0x6F
            case .f15: 0x71
            case .f4: 0x76
            case .f2: 0x78
            case .f1: 0x7A
            }
        }

        /// The key whose virtual key code is `code`; nil for a key no chord ends with, such as
        /// an arrow.
        public init?(code: UInt16) {
            guard let key = Self.allCases.first(where: { $0.code == code }) else { return nil }
            self = key
        }

        /// Whether it is an F-key, which may be a chord without a modifier.
        var isFunctionKey: Bool {
            rawValue.count > 1 && rawValue.first == "f" && Int(rawValue.dropFirst()) != nil
        }

        /// The F-keys as messages name them: "F1 to F20".
        static let functionKeyRange: String = {
            let keys = allCases.filter(\.isFunctionKey)
            guard let first = keys.first, let last = keys.last else {
                preconditionFailure("Key has no F-keys")
            }
            return "\(first.symbol) to \(last.symbol)"
        }()

        /// How a menu shows the key: "K", "7", "Space", "F5", ",".
        var symbol: String {
            switch self {
            case .space: "Space"
            case .return: "Return"
            case .tab: "Tab"
            case .escape: "Esc"
            case .comma: ","
            case .period: "."
            case .slash: "/"
            case .semicolon: ";"
            case .quote: "'"
            case .backslash: "\\"
            case .grave: "`"
            case .minus: "-"
            case .equal: "="
            case .leftBracket: "["
            case .rightBracket: "]"
            default: rawValue.uppercased()
            }
        }
    }

    /// Why a string isn't a chord, in a phrase that follows the string it quotes.
    public struct ParseError: Error, Equatable, Sendable {
        public let reason: String
    }

    public let modifiers: Modifiers
    public let key: Key

    public init(_ modifiers: Modifiers, _ key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    /// The chord `text` spells: modifiers `ctrl`, `opt`, `shift` and `cmd` in any order, each
    /// followed by `+`, then a key by its `Key` name, such as "cmd+space" or "ctrl+opt+k", in
    /// any case. A key that isn't an F-key needs a modifier other than shift alone, which would
    /// take the key away from typing.
    public init(parsing text: String) throws(ParseError) {
        guard !text.isEmpty else { throw ParseError(reason: "it is empty") }
        let parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last, !last.isEmpty else {
            throw ParseError(reason: "it has no key after the last +")
        }
        var modifiers: Modifiers = []
        for part in parts.dropLast() {
            guard
                let modifier = Modifiers.named.first(where: { $0.name == part.lowercased() })?
                    .modifier
            else {
                let names = Modifiers.named.map(\.name)
                throw ParseError(reason: "\"\(part)\" isn't a modifier: they are \(listed(names))")
            }
            guard !modifiers.contains(modifier) else {
                throw ParseError(reason: "it has \(part.lowercased()) twice")
            }
            modifiers.insert(modifier)
        }
        guard let key = Key(rawValue: last.lowercased()) else {
            throw ParseError(reason: "\"\(last)\" isn't a key")
        }
        try self.init(checking: modifiers, key)
    }

    /// `key` with `modifiers`, as a shortcut recorder sees them pressed, when the config file
    /// would take the chord: a key that isn't an F-key needs a modifier other than shift alone.
    public init(checking modifiers: Modifiers, _ key: Key) throws(ParseError) {
        if !key.isFunctionKey {
            let range = Key.functionKeyRange
            guard !modifiers.isEmpty else {
                throw ParseError(reason: "it needs a modifier, as only \(range) can be used alone")
            }
            guard modifiers != .shift else {
                throw ParseError(
                    reason: "shift alone would take the key from typing; only \(range) can be"
                        + " used with shift alone")
            }
        }
        self.init(modifiers, key)
    }

    /// The chord as the config file spells it: "ctrl+shift+k", modifiers in `Modifiers.named`'s
    /// order.
    public var text: String {
        let held = Modifiers.named.filter { modifiers.contains($0.modifier) }.map(\.name)
        return (held + [key.rawValue]).joined(separator: "+")
    }

    /// The chord as a menu shows it, for messages: "⌘Space", "⌃⌥K".
    public var description: String {
        Modifiers.named.filter { modifiers.contains($0.modifier) }.map(\.symbol).joined()
            + key.symbol
    }
}

/// `items` as a sentence lists them: "a, b and c".
private func listed(_ items: [String]) -> String {
    guard let last = items.last, items.count > 1 else { return items.joined() }
    return items.dropLast().joined(separator: ", ") + " and " + last
}
