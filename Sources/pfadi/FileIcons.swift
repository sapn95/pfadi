import AppKit

/// The icon for a row.
///
/// Almost always whatever LaunchServices says, which is the right answer and
/// the one every other application gives. The exception is the folders macOS
/// has an icon for but does not hand out: ask it for `~/.Trash` and it returns
/// a blank document sheet composited over a folder, which is what pfadi drew
/// until somebody looked at it. Finder shows a wastebasket there because Finder
/// substitutes its own.
enum FileIcons {
    /// Drawn at the size the list draws it, so AppKit picks the representation
    /// meant for that size rather than scaling a larger one.
    static let listSize = NSSize(width: 16, height: 16)

    static func icon(for url: URL, isDirectory: Bool) -> NSImage {
        let image =
            substitute(for: url, isDirectory: isDirectory)
            ?? NSWorkspace.shared.icon(forFile: url.path)
        // A copy, because `icon(forFile:)` hands back a shared instance and
        // resizing it would resize it everywhere it is already being drawn.
        let sized = image.copy() as? NSImage ?? image
        sized.size = listSize
        return sized
    }

    private static func substitute(for url: URL, isDirectory: Bool) -> NSImage? {
        guard isDirectory else { return nil }
        guard url.lastPathComponent == ".Trash",
            url.deletingLastPathComponent().resolvingSymlinksInPath().path
                == FileManager.default.homeDirectoryForCurrentUser
                .resolvingSymlinksInPath().path
        else { return nil }

        // Deliberately the empty one whatever is in there. Telling full from
        // empty means reading the folder, and reading `~/.Trash` needs a
        // permission this application has no business asking for to draw an
        // icon.
        return NSImage(named: NSImage.trashEmptyName)
    }
}
