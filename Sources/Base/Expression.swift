import Foundation

/// Arithmetic typed into the search field, evaluated to a number.
///
/// The grammar, loosest binding first:
///
///     sum      = product (("+" | "-") product)*
///     product  = unary (("*" | "/" | "mod") unary)*
///     unary    = ("-" | "+") unary | power
///     power    = percent ("^" unary)?
///     percent  = primary "%"*
///     primary  = number | constant | function argument | "(" sum ")"
///     argument = "(" sum ")" | unary
///
/// So `^` is right-associative and binds tighter than unary minus (`-2^2` is -4, `2^-1` is 0.5),
/// `50%` is 0.5, and `mod` takes the sign of the divisor (`-7 mod 3` is 2). A function takes a
/// parenthesized argument, after which `^` applies to its result (`sqrt(16)^2` is 16), or else
/// the unary expression after it (`sqrt 2^4` is 4). Numbers use `.` for decimals and may group
/// the integer part with `,` in threes (`1,000`). Constants are `pi` and `e`; functions are
/// `sqrt sin cos tan ln log abs round floor ceil`, with angles in radians and `log` in base 10.
/// Names ignore case. There is no implicit multiplication, so `2pi` is an error.
///
/// Text counts as a calculation only if it applies an operator other than a sign, or a function:
/// a bare number or constant, even signed or in parentheses, is `Error.notACalculation`.
public enum Expression {
    public enum Error: Swift.Error, Sendable, Equatable {
        /// No token starts with the character at this UTF-8 offset, as `$`, `×` or a `,` that
        /// doesn't separate thousands.
        case unexpectedCharacter(offset: Int)
        /// A word that is not a constant, a function or `mod`, as "password" in "1password".
        case unknownName(String)
        /// The token at this UTF-8 offset can't come where it is, as the second number in "1 2".
        case unexpectedToken(offset: Int)
        /// The text ends where the grammar needs more, as in "2+" or "(1".
        case unexpectedEnd
        /// Parentheses, signs, exponents or function calls nest deeper than `maximumDepth`.
        case tooDeep
        /// The text is a bare number or constant, with no operator or function.
        case notACalculation
        /// The result is infinite or not a number, as for `1/0` or `sqrt(-1)`.
        case notFinite
    }

    /// How deeply the parser may recurse. The parser recurses once per level of nesting, and a
    /// pasted run of thousands of `(` would otherwise overflow the stack.
    static let maximumDepth = 100

    /// The value of `text`, or the first error found in it.
    public static func evaluate(_ text: String) throws(Error) -> Double {
        var parser = Parser(tokens: try tokens(Array(text.utf8)))
        let value = try parser.sum()
        if let (_, offset) = parser.next { throw .unexpectedToken(offset: offset) }
        guard parser.isCalculation else { throw .notACalculation }
        guard value.isFinite else { throw .notFinite }
        return value
    }

    enum Function: String, CaseIterable {
        case sqrt, sin, cos, tan, ln, log, abs, round, floor, ceil

        func apply(_ x: Double) -> Double {
            switch self {
            case .sqrt: x.squareRoot()
            case .sin: Foundation.sin(x)
            case .cos: Foundation.cos(x)
            case .tan: Foundation.tan(x)
            case .ln: Foundation.log(x)
            case .log: log10(x)
            case .abs: Swift.abs(x)
            case .round: x.rounded()
            case .floor: x.rounded(.down)
            case .ceil: x.rounded(.up)
            }
        }
    }

    enum Token: Equatable {
        case number(Double)
        case function(Function)
        case plus, minus, times, divide, power, percent, mod, open, close
    }

    private static let symbols: [UInt8: Token] = [
        UInt8(ascii: "+"): .plus, UInt8(ascii: "-"): .minus, UInt8(ascii: "*"): .times,
        UInt8(ascii: "/"): .divide, UInt8(ascii: "^"): .power, UInt8(ascii: "%"): .percent,
        UInt8(ascii: "("): .open, UInt8(ascii: ")"): .close,
    ]

    /// `text`'s tokens, each with the UTF-8 offset it starts at.
    private static func tokens(_ text: [UInt8]) throws(Error) -> [(Token, Int)] {
        var tokens: [(Token, Int)] = []
        var index = 0
        while index < text.count {
            let start = index
            let byte = text[index]
            if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") {
                index += 1
            } else if let symbol = symbols[byte] {
                tokens.append((symbol, start))
                index += 1
            } else if isDigit(byte) || byte == UInt8(ascii: ".") {
                tokens.append((.number(try number(text, &index)), start))
            } else if isLetter(byte) {
                while index < text.count && isLetter(text[index]) { index += 1 }
                let name = String(decoding: text[start..<index], as: UTF8.self).lowercased()
                tokens.append((try token(named: name), start))
            } else {
                throw .unexpectedCharacter(offset: start)
            }
        }
        return tokens
    }

    private static func token(named name: String) throws(Error) -> Token {
        switch name {
        case "pi": return .number(.pi)
        case "e": return .number(M_E)
        case "mod": return .mod
        default:
            guard let function = Function(rawValue: name) else { throw .unknownName(name) }
            return .function(function)
        }
    }

    /// Reads the number starting at `index` and moves `index` past it. A `,` must have one to
    /// three digits before it at the number's start, or three after an earlier `,`, and exactly
    /// three digits after it.
    private static func number(_ text: [UInt8], _ index: inout Int) throws(Error) -> Double {
        var digits = ""
        var group = 0
        while index < text.count {
            let byte = text[index]
            if isDigit(byte) {
                digits.append(Character(UnicodeScalar(byte)))
                group += 1
            } else if byte == UInt8(ascii: ","), group <= 3,
                (1...3).allSatisfy({ index + $0 < text.count && isDigit(text[index + $0]) }),
                index + 4 >= text.count || !isDigit(text[index + 4])
            {
                group = 0
            } else if byte == UInt8(ascii: ",") {
                throw .unexpectedCharacter(offset: index)
            } else {
                break
            }
            index += 1
        }
        var fraction = ""
        if index < text.count && text[index] == UInt8(ascii: ".") {
            index += 1
            while index < text.count && isDigit(text[index]) {
                fraction.append(Character(UnicodeScalar(text[index])))
                index += 1
            }
        }
        if digits.isEmpty && fraction.isEmpty { throw .unexpectedCharacter(offset: index - 1) }
        let literal = (digits.isEmpty ? "0" : digits) + (fraction.isEmpty ? "" : "." + fraction)
        // Too many digits for a Double read as infinity, which the result check reports.
        guard let value = Double(literal) else {
            preconditionFailure("the lexer built \(literal), which Double can't read")
        }
        return value
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }

    /// A recursive-descent parser that evaluates as it parses, one method per grammar rule.
    private struct Parser {
        let tokens: [(Token, Int)]
        var position = 0
        var depth = 0
        /// Whether an operator other than a sign, or a function, has been applied.
        var isCalculation = false

        var next: (Token, Int)? { position < tokens.count ? tokens[position] : nil }

        /// Consumes the next token if it is one of `choices`.
        mutating func take(_ choices: Token...) -> Token? {
            guard let (token, _) = next, choices.contains(token) else { return nil }
            position += 1
            return token
        }

        mutating func sum() throws(Error) -> Double {
            var value = try product()
            while let token = take(.plus, .minus) {
                let right = try product()
                value = token == .plus ? value + right : value - right
                isCalculation = true
            }
            return value
        }

        mutating func product() throws(Error) -> Double {
            var value = try unary()
            while let token = take(.times, .divide, .mod) {
                let right = try unary()
                switch token {
                case .times: value *= right
                case .divide: value /= right
                default:
                    let remainder = value.truncatingRemainder(dividingBy: right)
                    value =
                        remainder != 0 && (remainder < 0) != (right < 0)
                        ? remainder + right : remainder
                }
                isCalculation = true
            }
            return value
        }

        /// Every path that nests goes through here, so this is where depth is counted.
        mutating func unary() throws(Error) -> Double {
            depth += 1
            defer { depth -= 1 }
            guard depth <= Expression.maximumDepth else { throw .tooDeep }
            if let sign = take(.minus, .plus) {
                let value = try unary()
                return sign == .minus ? -value : value
            }
            return try power()
        }

        mutating func power() throws(Error) -> Double {
            let base = try percent()
            guard take(.power) != nil else { return base }
            let exponent = try unary()
            isCalculation = true
            return pow(base, exponent)
        }

        mutating func percent() throws(Error) -> Double {
            var value = try primary()
            while take(.percent) != nil {
                value /= 100
                isCalculation = true
            }
            return value
        }

        mutating func primary() throws(Error) -> Double {
            guard let (token, offset) = next else { throw .unexpectedEnd }
            position += 1
            switch token {
            case .number(let value):
                return value
            case .open:
                let value = try sum()
                guard let (close, offset) = next else { throw .unexpectedEnd }
                guard close == .close else { throw .unexpectedToken(offset: offset) }
                position += 1
                return value
            case .function(let function):
                let argument = next?.0 == .open ? try primary() : try unary()
                isCalculation = true
                return function.apply(argument)
            default:
                throw .unexpectedToken(offset: offset)
            }
        }
    }
}
