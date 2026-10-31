import Testing

@testable import Base

private func value(_ text: String) -> Double? {
    try? Expression.evaluate(text)
}

private func error(_ text: String) -> Expression.Error? {
    do {
        _ = try Expression.evaluate(text)
        return nil
    } catch {
        return error
    }
}

@Test func followsPrecedenceAndAssociativity() {
    #expect(value("2*3+4") == 10)
    #expect(value("2+3*4") == 14)
    #expect(value("2^3^2") == 512)
    #expect(value("-2^2") == -4)
    #expect(value("2^-1") == 0.5)
    #expect(value("10-4-3") == 3)
    #expect(value("64/4/2") == 8)
    #expect(value("(2+3)*4") == 20)
    #expect(value(" 2 + 2 ") == 4)
    #expect(value("5--3") == 8)
    #expect(value("2*-3") == -6)
    #expect(value("1 + + 1") == 2)
}

@Test func takesPercentAndMod() {
    #expect(value("50%") == 0.5)
    #expect(value("10%*200") == 20)
    #expect(value("7 mod 3") == 1)
    #expect(value("-7 mod 3") == 2)
    #expect(value("7 mod -3") == -2)
    #expect(value("7 MOD 3") == 1)
    #expect(value("5%%") == 0.0005)
    #expect(value("10 mod 3 mod 2") == 1)
    #expect(error("10%5") == .unexpectedToken(offset: 3))
}

@Test func takesFunctionsAndConstants() {
    #expect(value("sqrt 16") == 4)
    #expect(value("sqrt(16)") == 4)
    #expect(value("sqrt(16)^2") == 16)
    #expect(value("sqrt 2^4") == 4)
    #expect(value("sqrt 16 + 1") == 5)
    #expect(value("abs -5") == 5)
    #expect(value("pi*2") == Double.pi * 2)
    #expect(value("ln e") == 1)
    #expect(value("log 1000") == 3)
    #expect(value("sin 0 + cos 0 + tan 0") == 1)
    #expect(value("round 2.5 + floor 1.9 + ceil 1.1") == 6)
    #expect(value("Sqrt(PI*PI)") == Double.pi)
}

@Test func readsTypographicOperatorsAndWhitespace() {
    #expect(value("2×3") == 6)
    #expect(value("6÷3") == 2)
    #expect(value("5−3") == 2)
    #expect(value("2\u{00A0}+\u{00A0}2") == 4)
    #expect(value("2+\n2\r\n") == 4)
}

@Test func readsExponents() {
    #expect(value("1e3*1") == 1000)
    #expect(value("2.5E-4*2") == 0.0005)
    #expect(value("1E+2+1") == 101)
    #expect(value("1.5E21*1") == 1.5e21)
    #expect(error("1e999*1") == .notFinite)
}

@Test func snapsRoundingNoiseToZero() {
    #expect(value("sin pi") == 0)
    #expect(value("cos(pi/2)") == 0)
    #expect(value("tan pi") == 0)
    #expect(value("1-0.9-0.1") == 0)
    #expect(value("1e-20*1") == 1e-20)
    #expect(value("sin 1e-20") == 1e-20)
    #expect(value("1e-20+0") == 1e-20)
    let tan = value("tan(pi/2)")
    #expect(tan.map { $0 > 1e15 } == true)
}

@Test func readsDecimalsAndThousandsSeparators() {
    #expect(value("1,000*2") == 2000)
    #expect(value("1,234,567.5+0") == 1_234_567.5)
    #expect(value(".5+1.") == 1.5)
    #expect(error("1,2+1") == .unexpectedCharacter(offset: 1))
    #expect(error("1,0000+1") == .unexpectedCharacter(offset: 1))
    #expect(error("1234,567+1") == .unexpectedCharacter(offset: 4))
    #expect(error("1.000,5+1") == .unexpectedCharacter(offset: 5))
}

@Test func rejectsWhatHasNoOperatorOrFunction() {
    for text in ["42", "-5", "+5", "--5", "(5)", "pi", "e", "-pi", "1,000", "1e3", "-1E-7"] {
        #expect(error(text) == .notACalculation, "\(text)")
    }
}

@Test func rejectsWordsThatAreNotNames() {
    #expect(error("safari") == .unknownName("safari"))
    #expect(error("1password") == .unknownName("password"))
    #expect(error("3d") == .unknownName("d"))
    #expect(error("1-password") == .unknownName("password"))
    #expect(error("2x3") == .unknownName("x"))
}

@Test func rejectsMalformedInput() {
    #expect(error("") == .unexpectedEnd)
    #expect(error("2+") == .unexpectedEnd)
    #expect(error("(1") == .unexpectedEnd)
    #expect(error("sqrt") == .unexpectedEnd)
    #expect(error("1)") == .unexpectedToken(offset: 1))
    #expect(error("2 pi") == .unexpectedToken(offset: 2))
    #expect(error("1 2") == .unexpectedToken(offset: 2))
    #expect(error("*2") == .unexpectedToken(offset: 0))
    #expect(error("2+$") == .unexpectedCharacter(offset: 2))
    #expect(error("2·3") == .unexpectedCharacter(offset: 1))
    #expect(error("2e") == .unexpectedToken(offset: 1))
    #expect(error(".") == .unexpectedCharacter(offset: 0))
}

@Test func rejectsResultsThatAreNotFinite() {
    #expect(error("1/0") == .notFinite)
    #expect(error("0/0") == .notFinite)
    #expect(error("sqrt(-1)") == .notFinite)
    #expect(error("5 mod 0") == .notFinite)
    #expect(error("10^400") == .notFinite)
    #expect(error(String(repeating: "9", count: 400) + "*1") == .notFinite)
    #expect(error("1/(1/0)") == .notFinite)
    #expect(error("1/ln(0)") == .notFinite)
    #expect(error("0*(1/0)+1") == .notFinite)
}

@Test func deepNestingIsAnErrorNotACrash() {
    let open = String(repeating: "(", count: 10_000)
    let close = String(repeating: ")", count: 10_000)
    #expect(error(open + "1+1" + close) == .tooDeep)
    #expect(error(String(repeating: "-", count: 10_000) + "1+1") == .tooDeep)
    #expect(error(String(repeating: "2^", count: 10_000) + "1") == .tooDeep)
}

@Test func nestsUpToTheMaximumDepth() {
    let depth = Expression.maximumDepth
    let nested = { (levels: Int) in
        String(repeating: "(", count: levels) + "1+1" + String(repeating: ")", count: levels)
    }
    #expect(value(nested(depth)) == 2)
    #expect(error(nested(depth + 1)) == .tooDeep)
    #expect(value(String(repeating: "-", count: depth) + "1+1") == 2)
    #expect(error(String(repeating: "-", count: depth + 1) + "1+1") == .tooDeep)
    #expect(value(String(repeating: "1^", count: depth) + "1") == 1)
    #expect(error(String(repeating: "1^", count: depth + 1) + "1") == .tooDeep)
}
