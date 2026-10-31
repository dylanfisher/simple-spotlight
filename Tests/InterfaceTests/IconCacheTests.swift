import AppKit
import Testing

@testable import Interface

/// Hands out one image per call, once let go, and counts the paths asked for.
private actor GatedLoader {
    private(set) var asked: [String] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func load(_ path: String) async -> NSImage {
        asked.append(path)
        await withCheckedContinuation { waiting.append($0) }
        return NSImage(size: NSSize(width: 1, height: 1))
    }

    /// Lets every load that is waiting finish; returns how many there were.
    func release() -> Int {
        let count = waiting.count
        for continuation in waiting { continuation.resume() }
        waiting = []
        return count
    }
}

@MainActor @Test func anIconIsMissingUntilItLoadsAndIsLoadedOnce() async {
    let loader = GatedLoader()
    let cache = IconCache(load: { await loader.load($0) })

    cache.request(["/Applications/Safari.app"])
    cache.request(["/Applications/Safari.app"])
    #expect(cache.image(for: "/Applications/Safari.app") == nil)
    #expect(cache.isRequested("/Applications/Safari.app"))

    while await loader.release() == 0 { await Task.yield() }
    while cache.image(for: "/Applications/Safari.app") == nil { await Task.yield() }

    #expect(await loader.asked == ["/Applications/Safari.app"])
}

@Test func theRealLoaderDrawsTheIconAtTwiceTheRowsSize() async throws {
    let image = await IconCache.render("/System/Applications/Calculator.app")

    let rep = try #require(image.representations.first as? NSBitmapImageRep)
    #expect(image.size == NSSize(width: ResultRow.iconSize, height: ResultRow.iconSize))
    #expect(rep.pixelsWide == Int(ResultRow.iconSize) * 2)
}

/// The icon fills its bitmap, rather than a corner of it at the size given in pixels.
@Test func theRealLoaderDrawsTheIconAcrossTheWholeBitmap() async throws {
    let image = await IconCache.render("/System/Applications/Calculator.app")

    let rep = try #require(image.representations.first as? NSBitmapImageRep)
    var drawn = (minX: Int.max, maxX: Int.min, minY: Int.max, maxY: Int.min)
    for x in 0..<rep.pixelsWide {
        for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
            drawn = (min(drawn.minX, x), max(drawn.maxX, x), min(drawn.minY, y), max(drawn.maxY, y))
        }
    }
    // App icons leave a margin around their shape, a tenth of the side or so.
    #expect(drawn.maxX - drawn.minX > rep.pixelsWide * 3 / 4)
    #expect(drawn.maxY - drawn.minY > rep.pixelsHigh * 3 / 4)
}

@MainActor @Test func aForgottenPathLoadsAgainAndALateLoadIsDropped() async {
    let loader = GatedLoader()
    let cache = IconCache(load: { await loader.load($0) })
    let path = "/Applications/Safari.app"

    cache.request([path])
    while await loader.asked.isEmpty { await Task.yield() }
    cache.forget([path])
    #expect(!cache.isRequested(path))
    #expect(await loader.release() == 1)
    // The forgotten load lands, and is dropped.
    while cache.finishedLoads == 0 { await Task.yield() }
    #expect(cache.image(for: path) == nil)

    cache.request([path])
    while await loader.release() == 0 { await Task.yield() }
    while cache.image(for: path) == nil { await Task.yield() }
    #expect(await loader.asked == [path, path])

    cache.forgetAll()
    #expect(cache.image(for: path) == nil)
    #expect(!cache.isRequested(path))
}
