import Base
import Foundation

/// Finds the user's scripts in the commands folder and turns each into a row that runs it.
public struct ScriptCommandProvider: Sendable {
    /// Scanned one level deep; subfolders are skipped.
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// One row per executable file, sorted by file name. Dotfiles and files whose names start
    /// with `_` are skipped. A missing folder gives nothing and no problem, since having the
    /// folder is how the feature is turned on. A file that isn't executable, or whose header
    /// can't be read, is left out and reported as a problem. Throws when cancelled.
    ///
    /// It blocks on the disk; callers go through `IndexBuilder.build()`, which runs it off the
    /// caller's actor.
    func items() throws(CancellationError) -> (items: [SearchItem], problems: [IndexProblem]) {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch CocoaError.fileReadNoSuchFile {
            return ([], [])
        } catch {
            return ([], [IndexProblem(folder, error)])
        }
        var items: [SearchItem] = []
        var problems: [IndexProblem] = []
        for name in names.sorted() where !name.hasPrefix(".") && !name.hasPrefix("_") {
            if Task.isCancelled { throw CancellationError() }
            let url = folder.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else { continue }
            do {
                let header = try Self.header(of: url)
                if header.errors.isEmpty {
                    items.append(Self.item(url, name: name, header: header))
                } else {
                    problems += header.errors.map {
                        IndexProblem(path: url.path, reason: "Line \($0.line): \($0.message).")
                    }
                }
            } catch {
                problems.append(IndexProblem(url, error))
            }
        }
        return (items, problems)
    }

    private static func item(_ url: URL, name: String, header: ScriptHeader) -> SearchItem {
        SearchItem(
            id: SearchItem.builtInID("commands/\(name)"), kind: .script, title: header.title,
            subtitle: header.subtitle, target: .runScript(url), alternateNames: header.keywords)
    }

    /// The header of the executable file at `url`, from its first bytes. One byte past
    /// `ScriptHeader.readLimit` is read so the parser can tell a line the limit cuts through.
    private static func header(of url: URL) throws -> ScriptHeader {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw IndexProblem(path: url.path, reason: "It isn't executable; run chmod +x on it.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        let data = try handle.read(upToCount: ScriptHeader.readLimit + 1) ?? Data()
        try handle.close()
        return ScriptHeader.parse([UInt8](data), fileName: url.lastPathComponent)
    }
}
