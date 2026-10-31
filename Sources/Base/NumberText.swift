import Foundation

/// A calculator answer as text, in two forms from one format: up to `significantDigits`
/// significant digits with no trailing zeros, in scientific notation ("1.5E21") when the rounded
/// value is below `scientificBelow` or at least `scientificFrom`.
public struct NumberText: Sendable, Equatable {
    static let significantDigits = 10
    /// JavaScript's thresholds for switching to scientific notation.
    static let scientificBelow = 1e-6
    static let scientificFrom = 1e21

    /// For display: the locale's grouping and decimal separators, as "1,234.5" or "1.234,5".
    public let grouped: String
    /// For copying: `.` for decimals, no grouping and `E` for an exponent in every locale, as
    /// "1234.5" or "1.5E21", so it pastes into code and back into the calculator.
    public let plain: String

    /// `value` must be finite; the calculator reports other results as errors before this.
    public init(_ value: Double, locale: Locale) {
        precondition(value.isFinite, "a non-finite answer \(value)")
        // Adding zero turns -0 into 0, so "-0*1" doesn't show "-0".
        let value = value + 0
        let posix = Locale(identifier: "en_US_POSIX")
        let style = FloatingPointFormatStyle<Double>.number
            .precision(.significantDigits(1...Self.significantDigits))
        let scientific = value.formatted(style.notation(.scientific).grouping(.never).locale(posix))
        // The form is chosen from the rounded value, so 0.00000099999999999 shows as 0.000001,
        // as 0.000001 does.
        guard let rounded = Double(scientific) else {
            preconditionFailure("the format style wrote \(scientific), which Double can't read")
        }
        let magnitude = Swift.abs(rounded)
        if magnitude != 0 && (magnitude < Self.scientificBelow || magnitude >= Self.scientificFrom)
        {
            grouped = value.formatted(style.notation(.scientific).locale(locale))
            plain = scientific
        } else {
            grouped = value.formatted(style.locale(locale))
            plain = value.formatted(style.grouping(.never).locale(posix))
        }
    }
}
