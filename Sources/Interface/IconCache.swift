import AppKit
import Observation

/// The Finder icons of the rows' files, loaded off the main actor and kept by path. A row shows
/// a placeholder until its icon lands; the rows redraw then, since they observe the cache.
@MainActor @Observable
public final class IconCache {
    /// Gives the icon of the file at the path, ready to draw without touching the disk.
    public typealias Load = @Sendable (String) async -> NSImage

    @ObservationIgnored private let load: Load
    private var images: [String: NSImage] = [:]
    /// Every path asked for, loaded or loading.
    @ObservationIgnored private var requested: Set<String> = []

    /// `load` defaults to `render`; tests replace it.
    public init(load: @escaping Load = { await IconCache.render($0) }) {
        self.load = load
    }

    /// The icon of the file at `path`, or nil until it has loaded.
    func image(for path: String) -> NSImage? {
        images[path]
    }

    /// Starts loading the icons of `paths` not already loaded or loading.
    public func request(_ paths: some Sequence<String>) {
        for path in paths where requested.insert(path).inserted {
            Task { [load] in
                images[path] = await load(path)
            }
        }
    }

    func isRequested(_ path: String) -> Bool {
        requested.contains(path)
    }

    /// The scale icons are drawn at. Every Mac display since 2012 is 2x or 1x; a 1x display
    /// scales the 2x bitmap down.
    nonisolated private static let scale: CGFloat = 2

    /// The icon of the file at `path`, drawn into a bitmap at `ResultRow.iconSize`. The
    /// workspace's icon reads the file and its icon resources lazily, when first drawn, so it is
    /// drawn here, off the main actor, and the main actor only ever draws the bitmap.
    @concurrent
    public nonisolated static func render(_ path: String) async -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        let size = NSSize(width: ResultRow.iconSize, height: ResultRow.iconSize)
        let pixels = Int(ResultRow.iconSize * scale)
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { preconditionFailure("can't make a \(pixels)-pixel bitmap") }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }
}
