import Foundation

/// Tab completion for the path field.
///
/// This is the reason the project exists: macOS has no address bar you can
/// click into and type, so the one thing that has to be right is turning
/// `/Users/sa` into `/Users/sapn/` without a detour through a dialog.
public enum PathCompletion {
    /// Candidate names for the word `partial` inside directory `prefix`.
    ///
    /// - Parameters:
    ///   - prefix: the text before the word being completed, e.g. `~/git/`.
    ///   - partial: the word being completed, e.g. `berndeu`.
    ///   - base: what a relative prefix is relative to, normally the folder on
    ///     screen. Without it, typing `sub/` and pressing tab offers nothing,
    ///     even though committing the same text navigates there perfectly well.
    /// - Returns: matching entry names, directories with a trailing slash so a
    ///   second tab keeps going instead of stopping at the folder.
    public static func candidates(
        prefix: String,
        partial: String,
        showHidden: Bool,
        base: URL? = nil,
        fileManager: FileManager = .default
    ) -> [String] {
        let directory = resolveDirectory(prefix, base: base, fileManager: fileManager)
        guard let directory else { return [] }

        let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []

        return
            contents
            .filter { name in
                if !showHidden, name.hasPrefix("."), !partial.hasPrefix(".") { return false }
                guard !partial.isEmpty else { return true }
                return name.range(of: partial, options: [.caseInsensitive, .anchored]) != nil
            }
            .map { name in
                var isDirectory: ObjCBool = false
                let path = directory.appendingPathComponent(name).path
                fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
                return isDirectory.boolValue ? name + "/" : name
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Whether this is the top: its parent is itself.
    ///
    /// A folder with no parent has no siblings either, which is why the
    /// leftmost part of a path cannot offer a menu of them and has to simply
    /// go there instead.
    public static func isRoot(_ url: URL) -> Bool {
        let path = directoryURL(url).path
        return path == directoryURL(url.deletingLastPathComponent()).path
    }

    /// One spelling for a directory URL.
    ///
    /// `URL(fileURLWithPath:)` asks the filesystem and appends a trailing slash
    /// when the path is a directory, `appendingPathComponent` does not. Two URLs
    /// for the same folder then compare unequal, which quietly breaks anything
    /// that asks "am I already there?" — going up from `/` for one.
    public static func directoryURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path, isDirectory: true).standardizedFileURL
    }

    /// Expands `~`, resolves a relative path against `base`, and returns it
    /// only if it is a directory that can actually be listed.
    public static func resolveDirectory(
        _ path: String,
        base: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return base.map(directoryURL) }

        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded)
        } else if let base {
            url = base.appendingPathComponent(expanded)
        } else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return directoryURL(url)
    }

    /// Resolves what the user typed into the path field.
    ///
    /// Returns the directory to navigate to, or the file to hand to the system,
    /// or nothing at all when the path does not exist. The caller decides how
    /// loudly to complain.
    public static func resolve(
        _ input: String,
        relativeTo current: URL,
        fileManager: FileManager = .default
    ) -> Target? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let url =
            expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : current.appendingPathComponent(expanded)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        return isDirectory.boolValue
            ? .directory(directoryURL(url))
            : .file(url.standardizedFileURL)
    }

    public enum Target: Equatable {
        case directory(URL)
        case file(URL)
    }
}
