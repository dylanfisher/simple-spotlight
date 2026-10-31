import AppKit
import SwiftUI

/// Hosts the rows. It never takes the keys, so a click between rows leaves them in the field.
@MainActor
final class ResultListHostingView: NSHostingView<SearchView> {
    override var acceptsFirstResponder: Bool { false }
}
