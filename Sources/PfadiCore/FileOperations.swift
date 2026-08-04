import Foundation

/// The first operations that touch the disk.
///
/// All three are reversible, which is why they come before copying and moving.
/// Trashing can be put back, a rename can be renamed again, and a folder that
/// was just created can be trashed. Anything that cannot be undone waits until
/// there is a progress and conflict story to hang it on.
public enum FileOperations {
    public enum NameProblem: Equatable {
        case empty
        case separator
        case reserved

        public var message: String {
            switch self {
            case .empty: return "a name cannot be empty"
            case .separator: return "a name cannot contain a slash"
            case .reserved: return "that name means something else to the filesystem"
            }
        }
    }

    /// Why a name cannot be used, or nil when it can.
    ///
    /// A leading dot is allowed on purpose: dotfiles are legitimate and this is
    /// a tool for people who have opinions about them. It will simply vanish
    /// from the list unless hidden files are shown.
    public static func problem(with name: String) -> NameProblem? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        // A slash cannot be in a POSIX name at all, and `:` is what Finder
        // shows a slash as, so someone typing one almost certainly means the
        // other and would get a surprise either way.
        if trimmed.contains("/") { return .separator }
        if trimmed == "." || trimmed == ".." { return .reserved }
        return nil
    }

    /// `untitled folder`, then `untitled folder 2`, and so on.
    ///
    /// Matches what Finder does, including starting at 2 rather than 1: the
    /// first one has no number, so `untitled folder 1` would be the second.
    public static func availableName(
        _ base: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> String {
        var candidate = base
        var counter = 2
        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }

    @discardableResult
    public static func createFolder(
        named name: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return URL(fileURLWithPath: url.path, isDirectory: true)
    }

    /// Renames in place. Fails rather than replacing anything already there.
    @discardableResult
    public static func rename(
        _ url: URL,
        to name: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        guard destination.path != url.path else { return url }
        // moveItem refuses an existing destination, which is the behaviour we
        // want: silently replacing a file during a rename loses it.
        try fileManager.moveItem(at: url, to: destination)
        return destination
    }

    /// Moves to the Trash and reports where it landed, so it can be put back.
    @discardableResult
    public static func trash(
        _ url: URL,
        fileManager: FileManager = .default
    ) throws -> URL? {
        var resulting: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}
