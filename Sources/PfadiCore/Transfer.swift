import Foundation

/// Working out what a copy or a move would actually do, before doing any of it.
///
/// Separated from carrying it out on purpose. Everything that can lose you
/// something is a decision made here: whether a folder is being dropped inside
/// itself, what collides with what, and which name a kept-both copy gets. All
/// of it is answerable without touching a byte, so all of it is tested.
public enum Transfer {
    public enum Kind: Equatable, Sendable {
        case copy
        case move
    }

    /// What to do about something already at the destination.
    public enum Resolution: Equatable, Sendable {
        /// The existing item goes to the trash first. Nothing is ever
        /// overwritten in place, so a wrong answer here is still recoverable.
        case replace
        case keepBoth
        case skip
    }

    public enum Refusal: Equatable, Error {
        case intoItself(URL)
        case intoOwnDescendant(URL)
        case sameFolder(URL)
        case missing(URL)

        public var message: String {
            switch self {
            case .intoItself(let url):
                return "\(url.lastPathComponent) cannot be put inside itself"
            case .intoOwnDescendant(let url):
                return "\(url.lastPathComponent) cannot be moved into a folder inside it"
            case .sameFolder:
                return "that is already where it is"
            case .missing(let url):
                return "\(url.lastPathComponent) is no longer there"
            }
        }
    }

    public struct Item: Equatable, Sendable {
        public let source: URL
        public let destination: URL
        public let isDirectory: Bool
        public let size: Int64

        public init(source: URL, destination: URL, isDirectory: Bool, size: Int64) {
            self.source = source
            self.destination = destination
            self.isDirectory = isDirectory
            self.size = size
        }
    }

    public struct Plan: Equatable {
        public let kind: Kind
        public let items: [Item]
        /// Destinations that already exist, in the order they were planned.
        public let conflicts: [URL]
        public let totalBytes: Int64

        public var isEmpty: Bool { items.isEmpty }
    }

    /// Checks a copy or move before anything happens.
    ///
    /// The two refusals worth having are both about a folder and its own
    /// insides. Copying a folder into itself walks forever; moving one into
    /// its own descendant detaches the branch you are standing on.
    public static func check(
        moving sources: [URL],
        into destination: URL,
        kind: Kind,
        fileManager: FileManager = .default
    ) -> Refusal? {
        let target = destination.standardizedFileURL
        for source in sources {
            let from = source.standardizedFileURL
            guard fileManager.fileExists(atPath: from.path) else { return .missing(from) }
            // Compared as paths, not as URLs. Foundation gives a directory URL
            // a trailing slash only when it has consulted the filesystem, so
            // two URLs for one folder are routinely unequal.
            if from.path == target.path { return .intoItself(from) }
            if isAncestor(from, of: target) { return .intoOwnDescendant(from) }
            if kind == .move, from.deletingLastPathComponent().path == target.path {
                return .sameFolder(from)
            }
        }
        return nil
    }

    /// Whether `folder` contains `candidate`, at any depth.
    ///
    /// Compares path components rather than string prefixes, or `/a/bc` would
    /// count as living inside `/a/b`.
    public static func isAncestor(_ folder: URL, of candidate: URL) -> Bool {
        let parent = folder.standardizedFileURL.pathComponents
        let child = candidate.standardizedFileURL.pathComponents
        guard child.count > parent.count else { return false }
        return Array(child.prefix(parent.count)) == parent
    }

    /// Flattens what is being transferred into one item per file and folder.
    ///
    /// A tree is expanded here rather than handed to a recursive copy, so the
    /// progress is honest about how much is left and a cancel lands between
    /// two files instead of somewhere inside a black box.
    public static func plan(
        _ sources: [URL],
        into destination: URL,
        kind: Kind,
        fileManager: FileManager = .default
    ) -> Plan {
        var items: [Item] = []
        var conflicts: [URL] = []
        var total: Int64 = 0

        for source in sources {
            let landing = destination.appendingPathComponent(source.lastPathComponent)
            if fileManager.fileExists(atPath: landing.path) {
                conflicts.append(landing)
            }

            for item in expand(source, to: landing, fileManager: fileManager) {
                items.append(item)
                total += item.size
            }
        }

        return Plan(kind: kind, items: items, conflicts: conflicts, totalBytes: total)
    }

    private static func expand(
        _ source: URL,
        to destination: URL,
        fileManager: FileManager
    ) -> [Item] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let values = try? source.resourceValues(forKeys: keys)
        let isDirectory = values?.isDirectory ?? false

        let here = Item(
            source: source,
            destination: destination,
            isDirectory: isDirectory,
            size: isDirectory ? 0 : Int64(values?.fileSize ?? 0)
        )
        guard isDirectory else { return [here] }

        // Not skipsHiddenFiles: a copy that quietly leaves out .git is not a
        // copy. Not following symlinks either, they are copied as links.
        let contents =
            (try? fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: Array(keys),
                options: []
            )) ?? []

        return contents.reduce(into: [here]) { result, child in
            result += expand(
                child,
                to: destination.appendingPathComponent(child.lastPathComponent),
                fileManager: fileManager
            )
        }
    }

    /// `report copy.pdf`, then `report copy 2.pdf`. Finder's spelling, because
    /// a folder full of files from two machines should sort together.
    public static func keepBothName(
        for url: URL,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        func assemble(_ stem: String) -> String {
            ext.isEmpty ? stem : "\(stem).\(ext)"
        }

        var candidate = assemble("\(name) copy")
        var counter = 2
        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = assemble("\(name) copy \(counter)")
            counter += 1
        }
        return candidate
    }
}
