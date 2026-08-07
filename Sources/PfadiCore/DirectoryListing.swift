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
        order: ListingOrder = .byName,
        fileManager: FileManager = .default
    ) throws -> [Entry] {
        // Deliberately not .localizedNameKey. It returns the name as Finder
        // would draw it, which drops the extension unless "Show all filename
        // extensions" is on, and translates system folders. In a tool built
        // around typing paths, the name on disk is the only useful one.
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
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

        // Worked out once for the folder rather than once per file. When the
        // folder is not in anybody's cloud, no entry can be a placeholder and
        // the per-file check is skipped entirely.
        let provider = CloudFiles.provider(for: directory)

        let entries = urls.map { url -> Entry in
            // A single unreadable entry must not lose the whole listing, so a
            // failed resource lookup degrades to a plain name instead of throwing.
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Entry(
                url: url,
                name: url.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                size: values?.fileSize.map(Int64.init),
                modified: values?.contentModificationDate,
                created: values?.creationDate,
                cloud: provider.map { found in
                    CloudFiles.Status(
                        provider: found.provider,
                        account: found.account,
                        isDownloaded: !CloudFiles.isDataless(url)
                    )
                } ?? .local
            )
        }

        return sorted(entries, by: order)
    }
}
