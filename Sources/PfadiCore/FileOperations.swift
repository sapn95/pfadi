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
    /// A name nothing in `directory` is already using.
    ///
    /// The number goes before the extension, not after it: "untitled 2.txt",
    /// never "untitled.txt 2". A name whose extension has a space and a digit
    /// in the middle of it is not a name macOS or anything else understands.
    public static func availableName(
        _ base: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> String {
        guard fileManager.fileExists(atPath: directory.appendingPathComponent(base).path) else {
            return base
        }

        // Split on the last dot rather than through URL, which would treat a
        // dotfile like ".zshrc" as all extension and no name.
        let url = URL(fileURLWithPath: base)
        let ext = url.pathExtension
        let stem =
            ext.isEmpty || base.hasPrefix(".")
            ? base : url.deletingPathExtension().lastPathComponent

        var counter = 2
        while true {
            let candidate =
                ext.isEmpty || base.hasPrefix(".")
                ? "\(stem) \(counter)"
                : "\(stem) \(counter).\(ext)"
            guard fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path)
            else { return candidate }
            counter += 1
        }
    }

    @discardableResult
    /// Makes an empty file and hands back where it landed.
    ///
    /// Refuses rather than truncating when something is already there: a
    /// "new file" that silently emptied an existing one would be the worst
    /// command in the application.
    public static func createFile(
        named name: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard !fileManager.fileExists(atPath: url.path) else {
            throw CocoaError(
                .fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
        }
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return url.standardizedFileURL
    }

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

    /// What happened when something was asked to go to the trash.
    public enum TrashOutcome: Equatable {
        /// Gone, and here is where it landed, when the system said where.
        case moved(URL?)
        /// Still exactly where it was, and why.
        case refused(String)
    }

    /// Trashes something and then checks that it actually went.
    ///
    /// `trashItem` cannot be taken at its word. Asked to trash `~/Documents` it
    /// returns without throwing, reports a resulting URL, and leaves the folder
    /// exactly where it was. There is no error to catch, which is why moving
    /// one of those folders to the trash appeared to work and silently did
    /// nothing at all.
    public static func trashChecking(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> TrashOutcome {
        let landed: URL?
        do {
            landed = try trash(url, fileManager: fileManager)
        } catch {
            return .refused(refusal(for: url, home: home, saying: error.localizedDescription))
        }
        guard exists(url) else { return .moved(landed) }
        return .refused(refusal(for: url, home: home, saying: nil))
    }

    /// Whether anything is at this path, symbolic link included.
    ///
    /// `lstat` rather than `fileExists`, which follows links: a link whose
    /// target is gone is still a link that is still there, and reporting it as
    /// trashed when it was refused is the mistake this whole function exists to
    /// stop making.
    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// Why something did not go to the trash, in words.
    private static func refusal(for url: URL, home: URL, saying message: String?) -> String {
        if isReservedHomeFolder(url, home: home) {
            return "macOS does not let this folder be moved to the trash"
        }
        // The system refused and gave no reason, which is worse than an error
        // message but better than a claim that it worked.
        return message ?? "the system refused, and left it where it was"
    }

    /// The folders macOS keeps for itself directly inside a home directory.
    ///
    /// By name and position rather than by asking, because there is nothing to
    /// ask: the refusal comes back as success, and the flag behind it is not
    /// exposed. `~/Documents` is one of these; `~/projects/Documents` is an
    /// ordinary folder with an unlucky name.
    public static func isReservedHomeFolder(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        // Apple's own, and only those. ~/Applications is a folder people make
        // themselves and ~/Sites has not been special since Mountain Lion;
        // calling either of them reserved would explain a refusal that never
        // happened and refuse to explain the real one.
        let reserved: Set<String> = [
            "Desktop", "Documents", "Downloads", "Library", "Movies", "Music",
            "Pictures", "Public",
        ]
        guard reserved.contains(url.lastPathComponent) else { return false }
        return url.deletingLastPathComponent().resolvingSymlinksInPath().path
            == home.resolvingSymlinksInPath().path
    }
}
