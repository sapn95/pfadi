import Foundation

/// The folders in the sidebar.
///
/// Stored as paths rather than bookmarks. A bookmark would survive a rename,
/// which sounds better until you remember that this list is mostly `~/git` and
/// `~/Downloads`: paths people know by heart and would look for by name.
public final class Favourites {
    private let preferences: Preferences
    private let fileManager: FileManager

    public init(preferences: Preferences = Preferences(), fileManager: FileManager = .default) {
        self.preferences = preferences
        self.fileManager = fileManager
    }

    /// What a first launch starts with. Everything here is a folder macOS
    /// makes for you, so it exists on any Mac.
    public static func defaults(home: URL) -> [String] {
        ["Desktop", "Documents", "Downloads"]
            .map { home.appendingPathComponent($0).path }
            .reduce(into: [home.path]) { $0.append($1) }
            + ["/Applications"]
    }

    /// The stored list, seeded on first use.
    public var paths: [String] {
        get {
            preferences.favourites
                ?? Self.defaults(home: fileManager.homeDirectoryForCurrentUser)
        }
        set { preferences.favourites = newValue }
    }

    /// The list as it should be drawn: existing directories only.
    ///
    /// A favourite can be deleted, renamed or unmounted between launches.
    /// Drawing a row that beeps when clicked is worse than not drawing it, and
    /// the entry stays in the stored list in case the volume comes back.
    public var visible: [URL] {
        paths.compactMap { path in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    /// Adds a folder, unless it is already there. Returns whether it was added,
    /// so the caller can say "already in the sidebar" rather than nothing.
    @discardableResult
    public func add(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard !paths.contains(path) else { return false }
        paths.append(path)
        return true
    }

    @discardableResult
    public func remove(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard let index = paths.firstIndex(of: path) else { return false }
        paths.remove(at: index)
        return true
    }

    public func contains(_ url: URL) -> Bool {
        paths.contains(url.standardizedFileURL.path)
    }

    /// The label for a row. Home gets a name rather than the account's short
    /// username, which is what the last path component would give.
    public static func title(for url: URL, home: URL) -> String {
        url.standardizedFileURL.path == home.standardizedFileURL.path
            ? "Home"
            : url.lastPathComponent
    }
}
