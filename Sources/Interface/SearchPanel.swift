import AppKit
import SwiftUI

/// The floating search window: a borderless panel that takes the keys without activating the
/// app, over every space and full-screen app, rounded over the system's blur, with the field on
/// top and the rows under it (docs/decisions/0008-search-panel-window.md).
@MainActor
final class SearchPanel: NSPanel {
    /// Offered each key equivalent before the panel's views; returns whether it took it. The
    /// app has no menu bar, so nothing else would see a Command chord.
    var keyEquivalent: @MainActor (NSEvent) -> Bool = { _ in false }
    /// Told, with the panel, when a click is about to make it key, before it does: with a panel
    /// on each display, the one clicked takes the keys from another, which then resigns them.
    var willTakeKeys: @MainActor (SearchPanel) -> Void = { _ in }
    let field = SearchField()

    static let width: CGFloat = 680
    static let fieldHeight: CGFloat = 56
    static let cornerRadius: CGFloat = 16
    /// The space above and below the rows, and either side of them.
    static let listInset: CGFloat = 6
    /// The line between the field and the rows.
    static let separatorHeight: CGFloat = 1
    /// How far below the top of the screen the panel's top sits, as a share of its height.
    static let topShare: CGFloat = 0.22
    /// What the field is called, to VoiceOver and in its placeholder.
    static let searchLabel = "Search"

    /// The space either side of the field's contents: left of the magnifier, right of the text.
    private static let sideMargin: CGFloat = 18
    private static let magnifierSize: CGFloat = 24
    /// The space between the magnifier and the text.
    private static let magnifierGap: CGFloat = 10
    private static let fieldLineHeight: CGFloat = 30

    /// The panel's height with `rows` rows under the field: the field alone with none.
    static func height(rows: Int) -> CGFloat {
        guard rows > 0 else { return fieldHeight }
        return fieldHeight + separatorHeight + 2 * listInset + CGFloat(rows) * ResultRow.height
    }

    /// The most rows a panel `height` tall has room for.
    static func rows(fitting height: CGFloat) -> Int {
        let room = height - fieldHeight - separatorHeight - 2 * listInset
        return max(Int((room / ResultRow.height).rounded(.down)), 0)
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
        field.placeholderString = Self.searchLabel
        field.setAccessibilityLabel(Self.searchLabel)
        field.setAccessibilitySubrole(.searchField)
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
        // The window server shapes the shadow from the pixels at the old size until told.
        if isVisible { invalidateShadow() }
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
        let symbol = Self.magnifierSize
        magnifier.frame = NSRect(
            x: Self.sideMargin, y: fieldTop + (Self.fieldHeight - symbol) / 2, width: symbol,
            height: symbol)
        let textLeft = Self.sideMargin + symbol + Self.magnifierGap
        field.frame = NSRect(
            x: textLeft, y: fieldTop + (Self.fieldHeight - Self.fieldLineHeight) / 2,
            width: Self.width - textLeft - Self.sideMargin, height: Self.fieldLineHeight)
        let rowsTop = fieldTop - Self.separatorHeight
        separator.isHidden = height <= Self.fieldHeight
        separator.frame = NSRect(
            x: 0, y: rowsTop, width: Self.width, height: Self.separatorHeight)
        rows?.frame = NSRect(x: 0, y: 0, width: Self.width, height: max(rowsTop, 0))
    }

    /// The field takes the keys; the panel does, though it has no title bar.
    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if !isKeyWindow, Self.clicks.contains(event.type) { willTakeKeys(self) }
        super.sendEvent(event)
    }

    private static let clicks: Set<NSEvent.EventType> = [
        .leftMouseDown, .rightMouseDown, .otherMouseDown,
    ]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyEquivalent(event) || super.performKeyEquivalent(with: event)
    }

    /// The content: the backdrop holding `content`, clipped to the rounded shape, with a
    /// hairline edge over it. The clip rounds the window server's shadow, which it shapes from
    /// the panel's pixels.
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

    /// The `.popover` blur, always active, as the panel only shows with the keys. Its tint is
    /// set by light or dark appearance alone, and what is behind only shows blurred through it.
    /// macOS 26's Liquid Glass, which Spotlight uses, turns lighter or darker with what is behind
    /// it, and no public setting holds it to the appearance. Reduce Transparency and Increase
    /// Contrast stay the system's.
    private static func makeBackdrop(holding content: NSView, bounds: NSRect) -> NSView {
        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .popover
        blur.blendingMode = .behindWindow
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

    /// White over the blur: stronger in light mode, where the blur is pale, fainter in dark
    /// mode, where it would glare.
    static let color = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(white: 1, alpha: isDark ? 0.2 : 0.6)
    }
}

/// The search field. The click that makes its panel key also places the caret.
@MainActor
final class SearchField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
