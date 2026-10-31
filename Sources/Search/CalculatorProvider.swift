import Base
import Foundation

/// Turns a query that is an arithmetic expression into the calculator's row.
public struct CalculatorProvider: Sendable {
    /// The id of every calculator row, whatever the expression, so usage counts the calculator
    /// once rather than once per expression typed.
    public static let itemID = "calculator"

    /// Sets the separators of the row's title. The copied answer is the same in every locale.
    public let locale: Locale

    public init(locale: Locale) {
        self.locale = locale
    }

    /// The row for `query`, or nil when the query isn't a calculation `Base.Expression` accepts
    /// or its answer isn't finite.
    public func item(for query: String) -> SearchItem? {
        // Any error means the query is something else, such as an app name.
        guard let value = try? Base.Expression.evaluate(query) else { return nil }
        let text = NumberText(value, locale: locale)
        return SearchItem(
            id: Self.itemID, kind: .calculation, title: "= \(text.grouped)",
            subtitle: query.trimmingCharacters(in: .whitespacesAndNewlines),
            target: .copyText(text.plain))
    }
}
