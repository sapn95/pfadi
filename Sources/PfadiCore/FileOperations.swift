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

    /// Where this would land if it went to the trash, or nil when the volume it
    /// is on has no trash at all.
    ///
    /// Asked rather than attempted. A network share has no trash, so ⌘⌫ there
    /// meant: try, fail, put the failure across the window, and wait to be asked
    /// a second time. The system will answer the question up front, which turns
    /// the same keystroke into one question with one answer.
    ///
    /// The folders macOS keeps in a home directory answer nil here too, and for
    /// a different reason: they have a trash and are simply not allowed into it.
    /// `canDeleteOutright` is what tells the two apart, so anything acting on
    /// this has to consult that as well.
    public static func trashLocation(
        for url: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        try? fileManager.url(
            for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false)
    }

    /// Whether the trash is even on offer for this.
    public static func hasTrash(for url: URL, fileManager: FileManager = .default) -> Bool {
        trashLocation(for: url, fileManager: fileManager) != nil
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
        guard let message else { return "the system refused, and left it where it was" }
        return withoutLeadingName(message)
    }

    /// Apple's message with the file name taken off the front of it.
    ///
    /// macOS phrases this one per file: `"Book.xlsx" couldn't be moved to the
    /// trash because the volume "Macintosh HD" doesn't have one.` Four files on
    /// a volume with no trash therefore give four reasons that differ only in a
    /// name the message already lists separately, so nothing collapses and the
    /// whole paragraph ends up in the band. Without the name they are one reason
    /// said once.
    ///
    /// By position rather than by matching the sentence: the wording is Apple's
    /// and is translated, the leading quoted name is not.
    public static func withoutLeadingName(_ message: String) -> String {
        // Both kinds of quote. The error uses curly ones, and anything
        // constructed in a test is likely to use straight ones.
        for quote in ["\u{201C}\u{201D}", "\"\""] {
            let open = quote.first!
            let close = quote.last!
            guard message.first == open,
                let end = message[message.index(after: message.startIndex)...]
                    .firstIndex(of: close)
            else { continue }
            let rest = message[message.index(after: end)...]
                .drop(while: { $0 == " " })
            // Only when something is left. A message that is nothing but a
            // quoted name says less without it than with it.
            if !rest.isEmpty { return String(rest) }
        }
        return message
    }

    /// Every reason, said once, and not all of them.
    ///
    /// macOS phrases a refusal per file, so four files on a volume with no trash
    /// give the same sentence four times with a different name in front of each.
    /// The names are already in the message; without them the four collapse into
    /// the one thing that is actually wrong.
    public static func summarise(reasons: [String]) -> String {
        let distinct = Set(reasons).sorted()
        // Two, because a third rarely adds anything and the band is three lines.
        // The count rather than the text for the rest: "and 5 more reasons" is
        // short and says there is more to find out, which a truncated sentence
        // does not.
        guard distinct.count > 2 else { return distinct.joined(separator: "; ") }
        let extra = distinct.count - 2
        return distinct.prefix(2).joined(separator: "; ")
            + "; and \(extra) more \(extra == 1 ? "reason" : "reasons")"
    }

    /// Removes something outright, with no trash in between.
    ///
    /// For the folders that have no trash of their own. A folder synced by
    /// OneDrive or iCloud lives under `~/Library/CloudStorage`, and macOS
    /// refuses to trash anything in one: there is nowhere on that volume for it
    /// to go. Removing it locally is what deleting it means there, because the
    /// sync then removes it on the server too.
    ///
    /// Nothing here can be undone, so every caller has to have asked first.
    public static func delete(
        _ url: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.removeItem(at: url)
    }

    /// Takes back something this application just made.
    ///
    /// The trash first, because an undo that can itself be undone is the better
    /// one. On a volume with no trash there is nothing to fall back to but
    /// removing it, and what is being removed is something pfadi created a
    /// moment ago because somebody asked, and has now been asked to take away.
    /// Without the fallback, ⌘Z after New Folder on a share failed outright and
    /// left the folder sitting there.
    ///
    /// Not for anything somebody else made: use `trashChecking` for that, which
    /// reports a refusal instead of answering it.
    @discardableResult
    public static func discard(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> URL? {
        switch trashChecking(url, home: home, fileManager: fileManager) {
        case .moved(let landed):
            return landed
        case .refused(let why):
            // Never the folders macOS keeps. Deleting ~/Documents for good to
            // honour a ⌘Z would be the worst thing this application could do,
            // and a caller cannot have created one of them to undo.
            guard canDeleteOutright(url, home: home) else {
                throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: why])
            }
            try delete(url, fileManager: fileManager)
            return nil
        }
    }

    /// Whether deleting outright is even worth offering for this.
    ///
    /// Not for the folders macOS keeps in a home directory. Their refusal is not
    /// a missing trash, it is macOS saying no, and answering it by deleting
    /// `~/Documents` for good would be the worst thing this application could
    /// do.
    public static func canDeleteOutright(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        !isReservedHomeFolder(url, home: home)
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
