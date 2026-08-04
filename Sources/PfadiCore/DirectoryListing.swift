import Foundation

/// Reads a directory into `Entry` values.
public enum DirectoryListing {
    /// Every entry in `directory`, directories first, then by name.
    ///
    /// Symlinks are reported as what they point at, which is what a person
    /// expects when they see a folder icon and press return on it.
    public static func read(
        _ directory: URL,
        showHidden: Bool,
        fileManager: FileManager = .default
    ) throws -> [Entry] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .localizedNameKey,
        ]
        var options: FileManager.DirectoryEnumerationOptions = []
        if !showHidden {
            options.insert(.skipsHiddenFiles)
        }

        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: options
        )

        let entries = urls.map { url -> Entry in
            // A single unreadable entry must not lose the whole listing, so a
            // failed resource lookup degrades to a plain name instead of throwing.
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Entry(
                url: url,
                name: values?.localizedName ?? url.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                size: values?.fileSize.map(Int64.init),
                modified: values?.contentModificationDate
            )
        }

        return sorted(entries)
    }

    /// Directories first, then case- and number-aware by name, so `img2`
    /// sorts before `img10` the way Finder does it.
    public static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
