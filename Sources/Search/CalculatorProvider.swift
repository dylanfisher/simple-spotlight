import Base
import Foundation

/// Turns a query that is an arithmetic expression into the calculator's row.
public struct CalculatorProvider: Sendable {
    /// The id of every calculator row, whatever the expression. Usage doesn't count it
    /// (docs/decisions/0010-usage-ranking.md).
    public static let itemID = "calculator"
    /// The Calculator app, whose icon the calculator's row shows.
    public static let calculatorApp = URL(
        fileURLWithPath: "/System/Applications/Calculator.app", isDirectory: true)

    /// Sets the separators of the row's title. The copied answer is the same in every locale.
    public let locale: Locale

    public init(locale: Locale) {
        self.locale = locale
    }

    /// The row for `query`, or nil when the query isn't a calculation `Base.Expression` accepts
    /// or its answer isn't finite. Its title is the answer, grouped as the locale does, and its
    /// subtitle the expression.
    public func item(for query: String) -> SearchItem? {
        // Any error means the query is something else, such as an app name.
        guard let value = try? Base.Expression.evaluate(query) else { return nil }
        let text = NumberText(value, locale: locale)
        return SearchItem(
            id: Self.itemID, kind: .calculation, title: text.grouped,
            subtitle: query.trimmingCharacters(in: .whitespacesAndNewlines),
            target: .copyText(text.plain))
    }
}
