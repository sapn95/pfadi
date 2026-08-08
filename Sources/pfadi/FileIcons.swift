import AppKit
import UniformTypeIdentifiers

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
            ?? openerIcon(for: url, isDirectory: isDirectory)
            ?? NSWorkspace.shared.icon(forFile: url.path)
        // A copy, because `icon(forFile:)` hands back a shared instance and
        // resizing it would resize it everywhere it is already being drawn.
        let sized = image.copy() as? NSImage ?? image
        sized.size = listSize
        return sized
    }

    /// The icon of the application that would open this file.
    ///
    /// Deliberately in place of the document icon rather than beside it. What
    /// somebody wants from a file list is to know what happens when they press
    /// return, and macOS's document icons only sometimes say: a .sketch file
    /// carries Sketch's branding, while half of everything else is the same
    /// white page. The trade is that a .png and a .jpg now look alike, because
    /// they open in the same thing — which is true, and the Kind column is
    /// there for when the difference matters.
    ///
    /// Folders are left alone: no application opens a folder, and the folder
    /// icon carries its colour and its emoji on Tahoe.
    private static func openerIcon(for url: URL, isDirectory: Bool) -> NSImage? {
        guard !isDirectory else { return nil }
        guard let application = opener(for: url) else { return nil }
        return NSWorkspace.shared.icon(forFile: application.path)
    }

    /// Which application opens this kind of file, cached by extension.
    ///
    /// Asked about the *type*, not about the file. Asking about the file looked
    /// equivalent and was not: a path that has since been deleted answers nil,
    /// and caching that nil under its extension told every later .txt that
    /// nothing opens it. Which is exactly what happened — every text file in
    /// the window lost its icon because one temporary file had been cleaned up
    /// first.
    ///
    /// The answer is a property of the type anyway, so this is also the
    /// question that was meant. A folder of forty thousand files has a handful
    /// of extensions between them.
    private static func opener(for url: URL) -> URL? {
        let key = url.pathExtension.lowercased()
        guard !key.isEmpty else {
            // No extension, so there is no type to ask about and the answer
            // belongs to this one file. Not cached for the same reason.
            return NSWorkspace.shared.urlForApplication(toOpen: url)
        }

        lock.lock()
        if let known = openers[key] {
            lock.unlock()
            return known
        }
        lock.unlock()

        let found = UTType(filenameExtension: key)
            .flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }

        lock.lock()
        openers[key] = found
        lock.unlock()
        return found
    }

    private static let lock = NSLock()
    /// Extension to application, with nil remembered too: a type nothing opens
    /// should not be asked about again on every redraw.
    nonisolated(unsafe) private static var openers: [String: URL?] = [:]

    /// Forgets which application opens what.
    ///
    /// Something can be installed while a window is open, and ⌘R is where
    /// somebody says "look again".
    static func forgetOpeners() {
        lock.lock()
        openers.removeAll()
        lock.unlock()
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
