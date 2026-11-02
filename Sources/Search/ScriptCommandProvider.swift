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
    /// folder is how the feature is turned on. A file that isn't executable, whose header
    /// can't be read, or that isn't a regular file (links are followed) is left out and reported
    /// as a problem. Throws when cancelled.
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
            do {
                switch try Self.kind(of: url) {
                case .directory: continue
                case .regularFile: break
                }
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

    private enum Kind { case directory, regularFile }

    /// What `url` is once links are followed. `stat` does the following; the keys of
    /// `URLResourceValues` on a link describe the link itself. Throws a problem for a link to
    /// nothing and for anything else that isn't a file or folder, such as a named pipe, which
    /// blocks the reader that opens it.
    private static func kind(of url: URL) throws -> Kind {
        var info = stat()
        if stat(url.path, &info) != 0 {
            let code = errno
            let isLink =
                (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
            throw IndexProblem(
                path: url.path,
                reason: code == ENOENT && isLink
                    ? "It's a link that points at nothing." : String(cString: strerror(code)) + ".")
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .regularFile
        default: throw IndexProblem(path: url.path, reason: "It isn't a regular file.")
        }
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
        let data: Data
        do {
            data = try handle.read(upToCount: ScriptHeader.readLimit + 1) ?? Data()
        } catch {
            try? handle.close()
            throw error
        }
        try handle.close()
        return ScriptHeader.parse([UInt8](data), fileName: url.lastPathComponent)
    }
}
