import Foundation

/// Whether a file is really here, or a placeholder for one that is not.
///
/// OneDrive, Dropbox, Google Drive and Box all go through the File Provider
/// machinery on modern macOS and live under `~/Library/CloudStorage`. Their
/// placeholder files look completely ordinary to `contentsOfDirectory`: they
/// have a name, a size and a date, and no bytes. Showing them as normal files
/// is how a copy of "everything" silently pulls a hundred gigabytes down a
/// metered connection.
public enum CloudFiles {
    /// The dataless flag in `st_flags`. Not exposed by name to Swift, so it is
    /// spelled out here rather than left as a bare number at the point of use.
    private static let datalessFlag: UInt32 = 0x4000_0000

    public struct Status: Equatable, Sendable {
        /// `OneDrive`, `Dropbox`, `iCloud Drive`, or nil for an ordinary file.
        public let provider: String?
        /// Which account or team, when the provider says. `SBB` in
        /// `OneDrive-SBB`.
        public let account: String?
        /// False when the file is a placeholder: it has a name and a size, and
        /// no bytes on this machine.
        public let isDownloaded: Bool

        public init(provider: String?, account: String?, isDownloaded: Bool) {
            self.provider = provider
            self.account = account
            self.isDownloaded = isDownloaded
        }

        public static let local = Status(provider: nil, account: nil, isDownloaded: true)

        public var isCloud: Bool { provider != nil }

        /// What to show a person, or nil when there is nothing to say.
        public var summary: String? {
            guard let provider else { return nil }
            let name = account.map { "\(provider) (\($0))" } ?? provider
            return isDownloaded ? "\(name), downloaded" : "\(name), online only"
        }
    }

    public static func status(of url: URL) -> Status {
        guard let (provider, account) = provider(for: url) else { return .local }
        return Status(provider: provider, account: account, isDownloaded: !isDataless(url))
    }

    /// Reads the provider out of the path.
    ///
    /// A path is a blunt instrument, but it is also the one thing that does not
    /// touch the file: asking the File Provider extension about an item is how
    /// you start a download of the thing you were only trying to describe.
    public static func provider(for url: URL) -> (provider: String, account: String?)? {
        let components = url.pathComponents

        // index > 0 before reaching back for Library: firstIndex can return 0,
        // and index - 1 on an Int array subscript is a crash, not a nil.
        if let index = components.firstIndex(of: "CloudStorage"),
            index > 0,
            components[index - 1] == "Library",
            components.indices.contains(index + 1)
        {
            // The folder is named `OneDrive-SBB`, `GoogleDrive-me@example.com`,
            // or just `Dropbox` when there is only one account.
            let folder = components[index + 1]
            guard let separator = folder.firstIndex(of: "-") else { return (folder, nil) }
            return (
                String(folder[folder.startIndex..<separator]),
                String(folder[folder.index(after: separator)...])
            )
        }

        // Anchored the same way. A folder somebody called "Mobile Documents"
        // in their own home is not iCloud, and saying it is would put a cloud
        // marker on files that are entirely here.
        if let index = components.firstIndex(of: "Mobile Documents"),
            index > 0,
            components[index - 1] == "Library"
        {
            return ("iCloud Drive", nil)
        }
        return nil
    }

    /// Whether the file is a placeholder with no bytes on this machine.
    ///
    /// `lstat` rather than anything higher level: it reads the directory entry
    /// and does not so much as open the file, which is what would trigger a
    /// download.
    public static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & datalessFlag != 0
    }
}
