import SwiftUI

/// The rows under the field, the selected one highlighted. A click opens its row.
struct SearchView: View {
    let state: SearchState
    let icons: IconCache
    /// The most rows shown: as many as fit on the panel's screen, which for a panel on another
    /// display can be fewer than `state` has.
    var limit = Int.max
    /// Opens the row at the index.
    let open: @MainActor (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(state.rows.prefix(limit).enumerated()), id: \.offset) { index, row in
                ResultRow(
                    row: row, image: image(for: row), isSelected: index == state.selection
                )
                .onTapGesture { open(index) }
            }
        }
        .padding(SearchPanel.listInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func image(for row: SearchState.Row) -> NSImage? {
        guard case .file(let path) = ResultRow.icon(for: row.item) else { return nil }
        return icons.image(for: path)
    }
}
