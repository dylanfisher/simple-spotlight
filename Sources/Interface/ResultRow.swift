import AppKit
import Search
import SwiftUI

/// One result: its icon, its title with the matched characters bold, and its subtitle; for the
/// calculator, its answer over its expression.
struct ResultRow: View {
    /// What a row's icon shows.
    enum Icon: Equatable {
        /// The Finder icon of the file at the path, loaded by `IconCache`.
        case file(String)
        /// A system symbol.
        case symbol(String)
    }

    nonisolated static let height: CGFloat = 48
    /// Most of the row's height, larger than the title and subtitle stacked, as Finder's list
    /// draws them. App icons leave a margin around their shape, so the shape itself is smaller.
    nonisolated static let iconSize: CGFloat = 40

    let row: SearchState.Row
    /// The loaded icon for a `.file` icon; nil until it loads.
    let image: NSImage?
    let isSelected: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 10) {
            iconView
                .frame(width: Self.iconSize, height: Self.iconSize)
            if row.item.kind == .calculation {
                calculationText
            } else {
                text
            }
            Spacer(minLength: 0)
        }
        .opacity(
            Self.contentOpacity(
                dimmed: row.dimmed, selected: isSelected, highContrast: contrast == .increased)
        )
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: Self.selectionFill))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: row.item))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The selected row's fill, under text in the colors unselected rows use, as Spotlight
    /// draws it: black over the light panel and white over the dark one, faint enough to read as
    /// a darker or lighter gray, stronger with Increase Contrast.
    static let selectionFill = NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ])
        return selectionFill(
            dark: match == .darkAqua || match == .accessibilityHighContrastDarkAqua,
            highContrast: match == .accessibilityHighContrastAqua
                || match == .accessibilityHighContrastDarkAqua)
    }

    /// `selectionFill` in a dark or light appearance, with or without Increase Contrast.
    nonisolated static func selectionFill(dark: Bool, highContrast: Bool) -> NSColor {
        NSColor(white: dark ? 1 : 0, alpha: (dark ? 0.12 : 0.09) * (highContrast ? 2 : 1))
    }

    /// The opacity of a row's icon and text: lower for a row not opened lately, so the apps in
    /// use stand out, but not for the selected row, which Return opens. Increase Contrast dims
    /// it less, as the subtitle is already secondary and fades with it.
    nonisolated static func contentOpacity(dimmed: Bool, selected: Bool, highContrast: Bool)
        -> Double
    {
        guard dimmed, !selected else { return 1 }
        return highContrast ? 0.7 : 0.55
    }

    /// The title with the matched characters bold, over the subtitle when there is one.
    private var text: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Self.title(row.item.title, bold: row.ranges))
                .font(.system(size: 15))
                .foregroundStyle(.primary)
            if let subtitle = row.item.subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }

    /// The answer, large, over the expression, quieter.
    private var calculationText: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(row.item.title)
                .font(.system(size: 20, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.primary)
            if let expression = row.item.subtitle {
                Text(expression)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }

    /// What VoiceOver reads for `item`'s row: its title, then its subtitle. A calculation reads
    /// "<expression> equals <answer>", since its answer is the title and the expression the
    /// subtitle. The panel announces the same text.
    nonisolated static func accessibilityLabel(for item: SearchItem) -> String {
        if item.kind == .calculation, let expression = item.subtitle {
            return "\(expression) equals \(item.title)"
        }
        return [item.title, item.subtitle].compactMap { $0 }.joined(separator: ", ")
    }

    @ViewBuilder
    private var iconView: some View {
        switch Self.icon(for: row.item) {
        case .file:
            if let image {
                Image(nsImage: image).resizable()
            } else {
                RoundedRectangle(cornerRadius: 9).fill(.quaternary)
                    .padding(4)
            }
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
        }
    }

    /// The icon of `item`'s row. Every settings pane shows the System Settings app's, as
    /// Spotlight's do, and the calculator's row the Calculator app's.
    nonisolated static func icon(for item: SearchItem) -> Icon {
        switch item.kind {
        case .settingsPane:
            return .file(SettingsPaneProvider.systemSettingsApp.path(percentEncoded: false))
        case .calculation:
            return .file(CalculatorProvider.calculatorApp.path(percentEncoded: false))
        case .command:
            return .symbol("gearshape")
        case .problem:
            return .symbol("exclamationmark.triangle")
        case .app:
            guard case .openFile(let url) = item.target else {
                preconditionFailure("the app \(item.id) has no file to open")
            }
            return .file(url.path(percentEncoded: false))
        }
    }

    /// `title` with the characters in `bold` strongly emphasized, which `Text` draws bold.
    nonisolated static func title(_ title: String, bold: [Range<String.Index>]) -> AttributedString
    {
        var shown = AttributedString()
        var rest = title.startIndex
        for range in bold.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            shown += AttributedString(title[rest..<range.lowerBound])
            var matched = AttributedString(title[range])
            matched.inlinePresentationIntent = .stronglyEmphasized
            shown += matched
            rest = range.upperBound
        }
        shown += AttributedString(title[rest...])
        return shown
    }
}
