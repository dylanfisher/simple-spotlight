import AppKit
import SwiftUI

/// The floating search window: a borderless panel that takes the keys without activating the
/// app, over every space and full-screen app, rounded over the system's glass or blur, with the
/// field on top and the rows under it (docs/decisions/0008-search-panel-window.md).
@MainActor
final class SearchPanel: NSPanel {
    /// Offered each key equivalent before the panel's views; returns whether it took it. The
    /// app has no menu bar, so nothing else would see a Command chord.
    var keyEquivalent: @MainActor (NSEvent) -> Bool = { _ in false }
    let field = NSTextField()

    static let width: CGFloat = 680
    static let fieldHeight: CGFloat = 56
    static let cornerRadius: CGFloat = 16
    /// The space above and below the rows, and either side of them.
    static let listInset: CGFloat = 6
    /// How far below the top of the screen the panel's top sits, as a share of its height.
    static let topShare: CGFloat = 0.22

    /// The panel's height with `rows` rows under the field: the field alone with none.
    static func height(rows: Int) -> CGFloat {
        guard rows > 0 else { return fieldHeight }
        return fieldHeight + 1 + 2 * listInset + CGFloat(rows) * ResultRow.height
    }

    /// Where the panel's top-left corner goes on a screen whose frame is `screen`: centered
    /// across it, its top `topShare` of the way down.
    static func topLeft(on screen: NSRect) -> NSPoint {
        NSPoint(x: screen.midX - width / 2, y: screen.maxY - screen.height * topShare)
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.fieldHeight),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        // The content clips itself to the rounded shape, so the shadow the window server draws
        // from its pixels is rounded too.
        hasShadow = true
        isReleasedWhenClosed = false
        // The app is rarely active while the panel shows, so losing the keys hides it, not the
        // app's deactivation.
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
    }

    /// Puts the field over `rows`, the rows' view, as the panel's content.
    func install(rows: NSView) {
        let bounds = NSRect(x: 0, y: 0, width: Self.width, height: Self.fieldHeight)
        let background = NSView(frame: bounds)
        background.autoresizingMask = [.width, .height]

        magnifier.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 20, weight: .regular)
        magnifier.contentTintColor = .secondaryLabelColor
        magnifier.setAccessibilityElement(false)

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 24, weight: .light)
        field.placeholderString = "Search"
        field.setAccessibilityLabel("Search")
        field.cell?.isScrollable = true
        field.cell?.wraps = false

        separator.boxType = .separator
        self.rows = rows

        for view in [magnifier, field, separator, rows] { background.addSubview(view) }
        contentView = Self.makeContent(holding: background, bounds: bounds)
        initialFirstResponder = field
        layoutContent()
    }

    /// Sets the height for `rows` rows, keeping the top edge where it is.
    func fit(rows: Int) {
        let height = Self.height(rows: rows)
        guard frame.height != height else { return }
        let top = frame.maxY
        setFrame(
            NSRect(x: frame.minX, y: top - height, width: Self.width, height: height),
            display: isVisible)
        layoutContent()
    }

    private let magnifier: NSImageView = {
        guard
            let image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        else { preconditionFailure("there is no system symbol magnifyingglass") }
        return NSImageView(image: image)
    }()
    private let separator = NSBox()
    private var rows: NSView?

    /// Places the field in the top `fieldHeight` and the rows under it, at the panel's height.
    private func layoutContent() {
        let height = frame.height
        let fieldTop = height - Self.fieldHeight
        let symbol: CGFloat = 24
        magnifier.frame = NSRect(
            x: 18, y: fieldTop + (Self.fieldHeight - symbol) / 2, width: symbol, height: symbol)
        let lineHeight: CGFloat = 30
        field.frame = NSRect(
            x: 52, y: fieldTop + (Self.fieldHeight - lineHeight) / 2, width: Self.width - 70,
            height: lineHeight)
        separator.isHidden = height <= Self.fieldHeight
        separator.frame = NSRect(x: 0, y: fieldTop - 1, width: Self.width, height: 1)
        rows?.frame = NSRect(x: 0, y: 0, width: Self.width, height: max(fieldTop - 1, 0))
    }

    /// The field takes the keys; the panel does, though it has no title bar.
    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyEquivalent(event) || super.performKeyEquivalent(with: event)
    }

    /// The content: the backdrop holding `content`, clipped to the rounded shape, with a
    /// hairline edge over it. The clip keeps the corners clear: the glass draws a faint fill over
    /// its whole rectangle while the panel is key, which would show as a square around it.
    private static func makeContent(holding content: NSView, bounds: NSRect) -> NSView {
        let clip = NSView(frame: bounds)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = cornerRadius
        clip.layer?.masksToBounds = true
        for view in [makeBackdrop(holding: content, bounds: bounds), EdgeView(frame: bounds)] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            clip.addSubview(view)
        }
        return clip
    }

    /// From macOS 26 the system's Liquid Glass, as Spotlight's; before it, the `.popover` blur,
    /// which follows light and dark appearance. Both leave Reduce Transparency and Increase
    /// Contrast to the system.
    private static func makeBackdrop(holding content: NSView, bounds: NSRect) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
        }
        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .popover
        blur.blendingMode = .behindWindow
        // The panel only shows with the keys; an inactive blur would go flat as it hides.
        blur.state = .active
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        blur.addSubview(content)
        return blur
    }
}

/// The panel's edge: a light hairline around its rounded shape, a pixel wide on any display.
@MainActor
private final class EdgeView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = SearchPanel.cornerRadius
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EdgeView is built in code")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = Self.color.cgColor
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// White over the glass: stronger in light mode, where the glass is pale, fainter in dark
    /// mode, where it would glare.
    static let color = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(white: 1, alpha: isDark ? 0.2 : 0.6)
    }
}
