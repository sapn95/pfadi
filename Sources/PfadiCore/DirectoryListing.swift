import Foundation

/// Reads a directory into `Entry` values.
public enum DirectoryListing {
    /// Every entry in `directory`, directories first, then by name.
    ///
    /// Symlinks are reported as what they point at, which is what a person
    /// expects when they see a folder icon and press return on it.
    ///
    /// - Parameter columns: which columns are on screen. Only what they need is
    ///   read: tags, owner and permissions each cost something per entry, and a
    ///   folder of forty thousand files should not pay for a column nobody has
    ///   switched on.
    public static func read(
        _ directory: URL,
        showHidden: Bool,
        order: ListingOrder = .byName,
        columns: [ListingColumn] = ListingColumn.byDefault,
        fileManager: FileManager = .default
    ) throws -> [Entry] {
        // Deliberately not .localizedNameKey. It returns the name as Finder
        // would draw it, which drops the extension unless "Show all filename
        // extensions" is on, and translates system folders. In a tool built
        // around typing paths, the name on disk is the only useful one.
        //
        // isDirectory is always asked for: folders sort above files whatever is
        // on screen, so it is not optional the way the rest are.
        var keys: Set<URLResourceKey> = [.isDirectoryKey]
        for column in columns {
            keys.formUnion(column.resourceKeys)
        }
        // The column being sorted by has to be read even when it is not shown:
        // a sort restored from last launch can name a column somebody has since
        // switched off, and sorting by a field that was never read puts the
        // list in an order with no explanation at all.
        if let sorted = ListingColumn.allCases.first(where: { $0.sortKey == order.key }) {
            keys.formUnion(sorted.resourceKeys)
        }
        let wantsStatus =
            columns.contains(where: \.needsFileStatus)
            || ListingColumn.allCases.first { $0.sortKey == order.key }?.needsFileStatus == true

        var options: FileManager.DirectoryEnumerationOptions = []
        if !showHidden {
            options.insert(.skipsHiddenFiles)
        }

        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: options
        )

        // Worked out once for the folder rather than once per file. When the
        // folder is not in anybody's cloud, no entry can be a placeholder and
        // the per-file check is skipped entirely.
        let provider = CloudFiles.provider(for: directory)

        let entries = urls.map { url -> Entry in
            // A single unreadable entry must not lose the whole listing, so a
            // failed resource lookup degrades to a plain name instead of throwing.
            let values = try? url.resourceValues(forKeys: keys)
            let status = wantsStatus ? FileStatus.read(url) : nil
            return Entry(
                url: url,
                name: url.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                size: values?.fileSize.map(Int64.init),
                modified: values?.contentModificationDate,
                created: values?.creationDate,
                added: values?.addedToDirectoryDate,
                opened: values?.contentAccessDate,
                kind: values?.localizedTypeDescription,
                tags: values?.tagNames ?? [],
                permissions: status?.permissions,
                owner: status?.owner,
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

/// Mode bits and ownership, the way `ls -l` shows them.
///
/// Read with `lstat` rather than through `URLResourceValues`, because those
/// follow symbolic links and the interesting thing about a link is the link.
enum FileStatus {
    struct Result {
        let permissions: String
        let owner: String
    }

    static func read(_ url: URL) -> Result? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Result(permissions: describe(info.st_mode), owner: name(forUID: info.st_uid))
    }

    private static func describe(_ mode: mode_t) -> String {
        let type: String
        switch mode & S_IFMT {
        case S_IFDIR: type = "d"
        case S_IFLNK: type = "l"
        case S_IFIFO: type = "p"
        case S_IFSOCK: type = "s"
        case S_IFBLK: type = "b"
        case S_IFCHR: type = "c"
        default: type = "-"
        }

        var text = type
        for shift in [6, 3, 0] {
            let bits = (mode >> mode_t(shift)) & 0o7
            text += bits & 0o4 != 0 ? "r" : "-"
            text += bits & 0o2 != 0 ? "w" : "-"
            text += bits & 0o1 != 0 ? "x" : "-"
        }

        // setuid, setgid and the sticky bit, in the places ls puts them.
        if mode & S_ISUID != 0 {
            text = replace(text, at: 3, with: mode & S_IXUSR != 0 ? "s" : "S")
        }
        if mode & S_ISGID != 0 {
            text = replace(text, at: 6, with: mode & S_IXGRP != 0 ? "s" : "S")
        }
        if mode & S_ISVTX != 0 {
            text = replace(text, at: 9, with: mode & S_IXOTH != 0 ? "t" : "T")
        }
        return text
    }

    private static func replace(_ text: String, at offset: Int, with character: Character) -> String
    {
        var characters = Array(text)
        guard characters.indices.contains(offset) else { return text }
        characters[offset] = character
        return String(characters)
    }

    /// Names are cached: a folder of forty thousand files has a handful of
    /// owners between them, and `getpwuid` is a lookup that can reach a
    /// directory service.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var names: [uid_t: String] = [:]

    private static func name(forUID uid: uid_t) -> String {
        lock.lock()
        if let known = names[uid] {
            lock.unlock()
            return known
        }
        lock.unlock()

        let resolved =
            getpwuid(uid).flatMap { String(validatingCString: $0.pointee.pw_name) }
            ?? String(uid)
        lock.lock()
        names[uid] = resolved
        lock.unlock()
        return resolved
    }
}
