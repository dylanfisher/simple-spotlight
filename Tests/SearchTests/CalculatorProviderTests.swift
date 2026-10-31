import Foundation
import Testing

@testable import Search

private let provider = CalculatorProvider(locale: Locale(identifier: "en_US"))

@Test func turnsAnExpressionIntoACalculatorItem() throws {
    let item = try #require(provider.item(for: " 1000+234.5 "))
    #expect(item.id == CalculatorProvider.itemID)
    #expect(item.kind == .calculation)
    #expect(item.title == "= 1,234.5")
    #expect(item.subtitle == "1000+234.5")
    #expect(item.target == .copyText("1234.5"))
}

@Test func keepsOneIDForEveryExpression() {
    #expect(provider.item(for: "2+2")?.id == provider.item(for: "3*3")?.id)
}

@Test func copiesPlainTextInAnyLocale() {
    let german = CalculatorProvider(locale: Locale(identifier: "de_DE"))
    let item = german.item(for: "1,000*1.5")
    #expect(item?.title == "= 1.500")
    #expect(item?.target == .copyText("1500"))
}

@Test func answersQueriesWithAnOperatorOrFunction() {
    for query in ["2+2", "sqrt 16", "sqrt(16)", "10%", "pi*2", "-5+1", "5 mod 3", "1,000*2"] {
        #expect(provider.item(for: query) != nil, "\(query)")
    }
}

@Test func givesNoItemForOtherQueries() {
    for query in [
        "", "42", "-5", "2048", "1,000", "pi", "e", "safari", "1password", "3d", "1-password",
        "2+", "(1", "1/0", "sqrt(-1)",
    ] {
        #expect(provider.item(for: query) == nil, "\(query)")
    }
}

@Suite(.serialized) struct CalculatorProviderTiming {
    /// B2 gives a keystroke 16 ms, and the calculator runs on each one. A calculation takes about
    /// 25 us in a debug build; the bound is the plan's "well under 1 ms". The first call loads the
    /// number formatter's data once and is left out.
    @Test func calculatesWithinBudget() {
        let query = "sqrt(1,234,567.89)^2 / (3 mod 2) + 10% - sin pi"
        #expect(provider.item(for: query) != nil)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<100 { _ = provider.item(for: query) }
        }
        #expect(elapsed / 100 < .milliseconds(1))
    }
}
