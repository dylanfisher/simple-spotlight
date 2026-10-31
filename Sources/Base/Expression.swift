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
/// the unary expression after it (`sqrt 2^4` is 4). `×`, `÷` and `−` (U+2212) stand for `*`, `/`
/// and `-`, and any Unicode whitespace separates tokens.
///
/// Numbers use `.` for decimals, may group the integer part with `,` in threes (`1,000`), and may
/// end in an exponent (`1.5E21`, `2e-4`). Constants are `pi` and `e`; functions are
/// `sqrt sin cos tan ln log abs round floor ceil`, with angles in radians and `log` in base 10.
/// Names ignore case. There is no implicit multiplication, so `2pi` and `2e` are errors.
///
/// Text counts as a calculation only if it applies an operator other than a sign, or a function:
/// a bare number or constant, even signed or in parentheses, is `Error.notACalculation`.
///
/// Every step must give a finite number, so `1/(1/0)` is `Error.notFinite` rather than 0. A sum,
/// difference, `sin`, `cos` or `tan` whose magnitude is below `noise` times its largest operand's
/// is 0: that is rounding left over from cancellation or from pi's inexact value, so `sin pi` and
/// `1-0.9-0.1` are 0.
public enum Expression {
    public enum Error: Swift.Error, Sendable, Equatable {
        /// No token starts with the character at this offset, counted in Unicode scalars, as `$`
        /// or a `,` that doesn't separate thousands.
        case unexpectedCharacter(offset: Int)
        /// A word that is not a constant, a function or `mod`, as "password" in "1password".
        case unknownName(String)
        /// The token at this offset, counted in Unicode scalars, can't come where it is, as the
        /// second number in "1 2".
        case unexpectedToken(offset: Int)
        /// The text ends where the grammar needs more, as in "2+" or "(1".
        case unexpectedEnd
        /// Parentheses, signs, exponents or function arguments nest deeper than `maximumDepth`.
        case tooDeep
        /// The text is a bare number or constant, with no operator or function.
        case notACalculation
        /// A step's result is infinite or not a number, as for `1/0` or `sqrt(-1)`.
        case notFinite
    }

    /// How many levels parentheses, signs, exponents and function arguments may nest. The parser
    /// recurses once per level, and a pasted run of thousands of `(` would otherwise overflow the
    /// stack.
    static let maximumDepth = 100

    /// The relative size below which a result counts as rounding noise. A Double holds about 16
    /// significant digits and the answer shows 10, so noise sits well below this and real results
    /// of cancellation that would show sit above it.
    static let noise = 1e-12

    /// The value of `text`, or the first error found in it.
    public static func evaluate(_ text: String) throws(Error) -> Double {
        var parser = Parser(tokens: try tokens(Array(text.unicodeScalars)))
        let value = try parser.sum()
        if let (_, offset) = parser.next { throw .unexpectedToken(offset: offset) }
        guard parser.isCalculation else { throw .notACalculation }
        return value
    }

    enum Function: String {
        case sqrt, sin, cos, tan, ln, log, abs, round, floor, ceil

        func apply(_ x: Double) -> Double {
            switch self {
            case .sqrt: x.squareRoot()
            case .sin: snapped(Foundation.sin(x), x)
            case .cos: snapped(Foundation.cos(x), x)
            case .tan: snapped(Foundation.tan(x), x)
            case .ln: Foundation.log(x)
            case .log: log10(x)
            case .abs: Swift.abs(x)
            case .round: x.rounded()
            case .floor: x.rounded(.down)
            case .ceil: x.rounded(.up)
            }
        }
    }

    /// `result`, or 0 when it is noise next to the largest of `operands`.
    static func snapped(_ result: Double, _ operands: Double...) -> Double {
        let scale = operands.map { Swift.abs($0) }.max() ?? 0
        return Swift.abs(result) < noise * scale ? 0 : result
    }

    enum Token: Equatable {
        case number(Double)
        case function(Function)
        case plus, minus, times, divide, power, percent, mod, open, close
    }

    private static let symbols: [Unicode.Scalar: Token] = [
        "+": .plus, "-": .minus, "\u{2212}": .minus, "*": .times, "×": .times, "/": .divide,
        "÷": .divide, "^": .power, "%": .percent, "(": .open, ")": .close,
    ]

    /// `text`'s tokens, each with the offset it starts at.
    private static func tokens(_ text: [Unicode.Scalar]) throws(Error) -> [(Token, Int)] {
        var tokens: [(Token, Int)] = []
        var index = 0
        while index < text.count {
            let start = index
            let scalar = text[index]
            if scalar.properties.isWhitespace {
                index += 1
            } else if let symbol = symbols[scalar] {
                tokens.append((symbol, start))
                index += 1
            } else if isDigit(scalar) || scalar == "." {
                tokens.append((.number(try number(text, &index)), start))
            } else if isLetter(scalar) {
                while index < text.count && isLetter(text[index]) { index += 1 }
                var name = String.UnicodeScalarView()
                name.append(contentsOf: text[start..<index])
                tokens.append((try token(named: String(name).lowercased()), start))
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
    /// three digits after it. An `e` or `E` is an exponent only when a digit follows it, or a
    /// sign and a digit; otherwise it is the constant `e`.
    private static func number(_ text: [Unicode.Scalar], _ index: inout Int) throws(Error)
        -> Double
    {
        func digit(at offset: Int) -> Bool { offset < text.count && isDigit(text[offset]) }
        func digits() -> String {
            var run = ""
            while digit(at: index) {
                run.unicodeScalars.append(text[index])
                index += 1
            }
            return run
        }
        var integer = ""
        var group = 0
        while index < text.count {
            let scalar = text[index]
            if isDigit(scalar) {
                integer.unicodeScalars.append(scalar)
                group += 1
            } else if scalar == ",", group <= 3, (1...3).allSatisfy({ digit(at: index + $0) }),
                !digit(at: index + 4)
            {
                group = 0
            } else if scalar == "," {
                throw .unexpectedCharacter(offset: index)
            } else {
                break
            }
            index += 1
        }
        var fraction = ""
        if index < text.count && text[index] == "." {
            index += 1
            fraction = digits()
        }
        if integer.isEmpty && fraction.isEmpty { throw .unexpectedCharacter(offset: index - 1) }
        var exponent = ""
        if index < text.count && (text[index] == "e" || text[index] == "E") {
            let signed =
                index + 1 < text.count && (text[index + 1] == "+" || text[index + 1] == "-")
            if digit(at: index + (signed ? 2 : 1)) {
                exponent = "e" + (signed ? String(text[index + 1]) : "")
                index += signed ? 2 : 1
                exponent += digits()
            }
        }
        let literal =
            (integer.isEmpty ? "0" : integer) + (fraction.isEmpty ? "" : "." + fraction) + exponent
        // Too many digits or too large an exponent read as infinity, which the parser reports.
        guard let value = Double(literal) else {
            preconditionFailure("the lexer built \(literal), which Double can't read")
        }
        return value
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    /// A recursive-descent parser that evaluates as it parses, one method per grammar rule.
    private struct Parser {
        let tokens: [(Token, Int)]
        var position = 0
        /// How many levels deep the current `unary` is: 0 at the top.
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

        /// `value` when finite, as every step's result must be.
        func finite(_ value: Double) throws(Error) -> Double {
            guard value.isFinite else { throw .notFinite }
            return value
        }

        mutating func sum() throws(Error) -> Double {
            var value = try product()
            while let token = take(.plus, .minus) {
                let right = try product()
                value = try finite(
                    Expression.snapped(token == .plus ? value + right : value - right, value, right)
                )
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
                value = try finite(value)
                isCalculation = true
            }
            return value
        }

        /// Every path that nests goes through here, so this is where depth is counted.
        mutating func unary() throws(Error) -> Double {
            guard depth <= Expression.maximumDepth else { throw .tooDeep }
            depth += 1
            defer { depth -= 1 }
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
            return try finite(pow(base, exponent))
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
                return try finite(value)
            case .open:
                let value = try sum()
                guard let (close, offset) = next else { throw .unexpectedEnd }
                guard close == .close else { throw .unexpectedToken(offset: offset) }
                position += 1
                return value
            case .function(let function):
                let argument = next?.0 == .open ? try primary() : try unary()
                isCalculation = true
                return try finite(function.apply(argument))
            default:
                throw .unexpectedToken(offset: offset)
            }
        }
    }
}
