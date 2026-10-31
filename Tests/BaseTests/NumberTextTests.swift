import Foundation
import Testing

@testable import Base

private let english = Locale(identifier: "en_US")
private let german = Locale(identifier: "de_DE")

private func text(_ value: Double, _ locale: Locale = english) -> (String, String) {
    let text = NumberText(value, locale: locale)
    return (text.grouped, text.plain)
}

@Test func roundsWithoutTrailingZeros() {
    #expect(text(0.1 + 0.2) == ("0.3", "0.3"))
    #expect(text(2.0 / 3) == ("0.6666666667", "0.6666666667"))
    #expect(text(4) == ("4", "4"))
    #expect(text(-2.5) == ("-2.5", "-2.5"))
    #expect(text(1_234_567_891_234) == ("1,234,567,891,000", "1234567891000"))
}

@Test func groupsOnlyTheDisplayedForm() {
    #expect(text(1234.5) == ("1,234.5", "1234.5"))
    #expect(text(1234.5, german) == ("1.234,5", "1234.5"))
    #expect(text(-1_000_000, german) == ("-1.000.000", "-1000000"))
}

@Test func usesScientificFormForHugeAndTinyNumbers() {
    #expect(text(1e21) == ("1E21", "1E21"))
    #expect(text(-1.5e30, german) == ("-1,5E30", "-1.5E30"))
    #expect(text(1.5e-7) == ("1.5E-7", "1.5E-7"))
    #expect(text(1e20) == ("100,000,000,000,000,000,000", "100000000000000000000"))
    #expect(text(0.000001) == ("0.000001", "0.000001"))
    #expect(text(-1e-7) == ("-1E-7", "-1E-7"))
}

@Test func choosesTheFormAfterRounding() {
    let below = NumberText.scientificBelow
    let from = NumberText.scientificFrom
    #expect(text(below.nextDown) == text(below))
    #expect(text(0.00000099999999999) == text(0.000001))
    #expect(text(from.nextDown) == text(from))
    #expect(text(from.nextDown).1.contains("E"))
    #expect(text(below.nextDown).1.contains("E") == false)
}

@Test func keepsTheSignificantDigits() {
    // Pi has more digits than any count the calculator would show.
    #expect(text(.pi * 1000).1.filter(\.isNumber).count == NumberText.significantDigits)
}

@Test func zeroHasNoSign() {
    #expect(text(-0.0) == ("0", "0"))
    #expect(text(0) == ("0", "0"))
}
