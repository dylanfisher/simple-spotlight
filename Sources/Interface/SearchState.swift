import Observation
import Search

/// What the rows show: set by `SearchPanelController`, read by `SearchView`.
@MainActor @Observable
final class SearchState {
    /// One row: its item, and the characters of its title the query matched.
    struct Row {
        let item: SearchItem
        /// Ranges of `item.title`; empty when nothing in the title is to be bold.
        let ranges: [Range<String.Index>]
    }

    var rows: [Row] = []
    /// The index in `rows` of the selected row; 0 when there are none.
    var selection = 0
}
