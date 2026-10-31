import AppKit
import SwiftUI

/// Hosts the rows. It never takes the keys, so a click between rows leaves them in the field.
@MainActor
final class ResultListHostingView: NSHostingView<SearchView> {
    override var acceptsFirstResponder: Bool { false }

    /// The click that makes a panel key on another display also selects or opens the row.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
