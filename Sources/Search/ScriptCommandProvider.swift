import Base
import Foundation

/// Finds the user's scripts in the commands folder and turns each into a row that runs it, and
/// each subfolder into a group row that shows the rows inside it.
public struct ScriptCommandProvider: Sendable {
    /// What one scan found.
    public struct Tree: Sendable {
        /// The top level's rows: each command and group directly in the folder, then each one
        /// deeper marked `@top-level`.
        public let items: [SearchItem]
        /// Each group's rows, keyed by the group's id: the commands and groups directly in it.
        /// An empty group has an empty list.
        public let groups: [String: [SearchItem]]
        public let problems: [IndexProblem]
    }

    /// The file in a group's folder whose header names the group. It is never run.
    static let groupFile = "_group"

    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// The rows of the commands folder and its groups, at any depth. In each folder the rows are
    /// in file name order, as Finder sorts names. Dotfiles and names that start with `_` are
    /// skipped, other than `_group`, which is read for its group's header. A missing folder
    /// gives nothing and no problem, since having the folder is how the feature is turned on.
    /// A script that isn't executable, a header that can't be read, or a file that isn't a
    /// regular file or folder (links are followed) is left out and reported as a problem. A
    /// group whose `_group` can't be read is still shown, under its folder's name. Throws when
    /// cancelled.
    ///
    /// It blocks on the disk; callers go through `IndexBuilder.build()`, which runs it off the
    /// caller's actor.
    func items() throws(CancellationError) -> Tree {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch CocoaError.fileReadNoSuchFile {
            return Tree(items: [], groups: [:], problems: [])
        } catch {
            return Tree(items: [], groups: [:], problems: [IndexProblem(folder, error)])
        }
        var scan = Scan()
        let rows = try scan.rows(in: folder, names: names, path: nil, groupTitle: nil)
        return Tree(items: rows + scan.promoted, groups: scan.groups, problems: scan.problems)
    }

    /// What a scan has found so far, besides the rows of the folder being scanned.
    private struct Scan {
        /// The rows below the top level marked `@top-level`, as the top level shows them.
        var promoted: [SearchItem] = []
        var groups: [String: [SearchItem]] = [:]
        var problems: [IndexProblem] = []

        /// The rows of `folder`, whose entries are `names`. `path` is the folder's path inside
        /// the commands folder, nil for the commands folder itself, and `groupTitle` its title.
        mutating func rows(
            in folder: URL, names: [String], path: String?, groupTitle: String?
        ) throws(CancellationError) -> [SearchItem] {
            var rows: [SearchItem] = []
            for name in ordered(names) where !name.hasPrefix(".") && !name.hasPrefix("_") {
                if Task.isCancelled { throw CancellationError() }
                let url = folder.appendingPathComponent(name)
                let relative = path.map { "\($0)/\(name)" } ?? name
                let found: (item: SearchItem, isTopLevel: Bool)?
                do {
                    switch try kind(of: url) {
                    case .linkToFolder: found = nil
                    case .folder: found = try group(at: url, path: relative)
                    case .regularFile: found = try script(at: url, path: relative)
                    }
                } catch let error as CancellationError {
                    throw error
                } catch {
                    problems.append(IndexProblem(url, error))
                    continue
                }
                guard let found else { continue }
                rows.append(found.item)
                if found.isTopLevel, let groupTitle {
                    promoted.append(promote(found.item, groupTitle: groupTitle))
                }
            }
            return rows
        }

        /// The row of the script at `url`, or nil when its header has errors, which become
        /// problems.
        private mutating func script(at url: URL, path: String) throws -> (SearchItem, Bool)? {
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw IndexProblem(
                    path: url.path, reason: "It isn't executable; run chmod +x on it.")
            }
            let header = ScriptHeader.parse(
                try leadingBytes(of: url), fileName: url.lastPathComponent)
            guard header.errors.isEmpty else {
                report(header, of: url)
                return nil
            }
            let item = SearchItem(
                id: id(path), kind: .script, title: header.title, subtitle: header.subtitle,
                target: .runScript(url), alternateNames: header.keywords)
            return (item, header.isTopLevel)
        }

        /// The row of the group in the folder at `url`, after scanning its rows into `groups`.
        /// Nil when the folder can't be listed.
        private mutating func group(
            at url: URL, path: String
        ) throws(CancellationError) -> (SearchItem, Bool)? {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            } catch {
                problems.append(IndexProblem(url, error))
                return nil
            }
            let defaultTitle = url.lastPathComponent
            var header = ScriptHeader.parse([], defaultTitle: defaultTitle)
            if names.contains(groupFile) {
                let file = url.appendingPathComponent(groupFile)
                do {
                    guard try kind(of: file) == .regularFile else {
                        throw IndexProblem(path: file.path, reason: "It isn't a regular file.")
                    }
                    let read = ScriptHeader.parse(
                        try leadingBytes(of: file), defaultTitle: defaultTitle)
                    if read.errors.isEmpty { header = read } else { report(read, of: file) }
                } catch {
                    problems.append(IndexProblem(file, error))
                }
            }
            let groupID = id(path)
            groups[groupID] = try rows(in: url, names: names, path: path, groupTitle: header.title)
            let item = SearchItem(
                id: groupID, kind: .group, title: header.title, subtitle: header.subtitle,
                target: .openGroup(groupID), alternateNames: header.keywords)
            return (item, header.isTopLevel)
        }

        private mutating func report(_ header: ScriptHeader, of url: URL) {
            problems += header.errors.map {
                IndexProblem(path: url.path, reason: "Line \($0.line): \($0.message).")
            }
        }
    }

    /// The id of the script or group at `path` inside the commands folder. A `@top-level` row
    /// has the same id at the top level and in its group, so they share usage.
    private static func id(_ path: String) -> String {
        SearchItem.builtInID("\(HomePath.scriptCommandsName)/\(path)")
    }

    /// `item` as the top level shows it: its group's title is its subtitle when it has none.
    private static func promote(_ item: SearchItem, groupTitle: String) -> SearchItem {
        SearchItem(
            id: item.id, kind: item.kind, title: item.title,
            subtitle: item.subtitle ?? groupTitle, target: item.target,
            alternateNames: item.alternateNames)
    }

    /// `names` as Finder orders them: case aside and numbers by value, so `Input 2` comes
    /// before `Input 10` and `lock-screen` before `TV`. Names that compare the same, as two
    /// differing only in case can on a case-sensitive volume, fall back to byte order, so the
    /// order never depends on the listing's.
    private static func ordered(_ names: [String]) -> [String] {
        names.sorted {
            switch $0.localizedStandardCompare($1) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: $0 < $1
            }
        }
    }

    private enum Kind { case folder, linkToFolder, regularFile }

    /// What `url` is once links are followed. `stat` does the following; the keys of
    /// `URLResourceValues` on a link describe the link itself. A link to a folder isn't a group:
    /// FSEvents doesn't follow links, so changes in the folder wouldn't update the index, and a
    /// link up the tree would make the scan loop. Throws a problem for a link to nothing and for
    /// anything else that isn't a file or folder, such as a named pipe, which blocks the reader
    /// that opens it.
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
        case S_IFDIR:
            var own = stat()
            guard lstat(url.path, &own) == 0 else {
                throw IndexProblem(path: url.path, reason: String(cString: strerror(errno)) + ".")
            }
            return own.st_mode & S_IFMT == S_IFLNK ? .linkToFolder : .folder
        case S_IFREG: return .regularFile
        default: throw IndexProblem(path: url.path, reason: "It isn't a regular file.")
        }
    }

    /// The first bytes of the file at `url`, for its header. One byte past
    /// `ScriptHeader.readLimit` is read so the parser can tell a line the limit cuts through.
    private static func leadingBytes(of url: URL) throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: url)
        let data: Data
        do {
            data = try handle.read(upToCount: ScriptHeader.readLimit + 1) ?? Data()
        } catch {
            try? handle.close()
            throw error
        }
        try handle.close()
        return [UInt8](data)
    }
}
