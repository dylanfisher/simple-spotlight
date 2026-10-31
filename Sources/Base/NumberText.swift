import Foundation

/// A calculator answer as text, in two forms from one format: up to 10 significant digits with
/// no trailing zeros, and scientific notation ("1.5E21") below 1e-6 or from 1e21 up.
public struct NumberText: Sendable, Equatable {
    /// For display: the locale's grouping and decimal separators, as "1,234.5" or "1.234,5".
    public let grouped: String
    /// For copying: `.` for decimals and no grouping in every locale, as "1234.5", so it pastes
    /// into code and back into the calculator.
    public let plain: String

    /// `value` must be finite; the calculator reports other results as errors before this.
    public init(_ value: Double, locale: Locale) {
        precondition(value.isFinite, "a non-finite answer \(value)")
        // Adding zero turns -0 into 0, so "-0*1" doesn't show "-0".
        let value = value + 0
        // Compared before rounding, so a value just under 1e21 shows its rounded decimal form.
        let magnitude = Swift.abs(value)
        let scientific = magnitude != 0 && (magnitude < 1e-6 || magnitude >= 1e21)
        let style = FloatingPointFormatStyle<Double>.number
            .precision(.significantDigits(1...10))
            .notation(scientific ? .scientific : .automatic)
        grouped = value.formatted(style.locale(locale))
        plain = value.formatted(style.grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }
}
