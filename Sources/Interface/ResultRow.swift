import AppKit
import Search
import SwiftUI

/// One result: its icon, its title with the matched characters bold, and its subtitle.
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

    var body: some View {
        HStack(spacing: 10) {
            iconView
                .frame(width: Self.iconSize, height: Self.iconSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(row.item.title, bold: row.ranges))
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                if let subtitle = row.item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(
                            isSelected
                                ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: row.item))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// What VoiceOver reads for `item`'s row: its title, then its subtitle.
    nonisolated static func accessibilityLabel(for item: SearchItem) -> String {
        [item.title, item.subtitle].compactMap { $0 }.joined(separator: ", ")
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
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        }
    }

    /// The icon of `item`'s row. Every settings pane shows the System Settings app's, as
    /// Spotlight's do.
    nonisolated static func icon(for item: SearchItem) -> Icon {
        switch item.kind {
        case .settingsPane:
            return .file(SettingsPaneProvider.systemSettingsApp.path(percentEncoded: false))
        case .calculation:
            return .symbol("plus.forwardslash.minus")
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
