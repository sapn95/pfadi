import Foundation

/// Typing `smb://server/share` into the path field and having it work.
///
/// The premise of this application is that the address bar takes an address.
/// A share is an address, so it belongs in the same field rather than behind a
/// separate dialog with its own history and its own idea of what you meant.
public enum NetworkShare {
    /// cifs is smb under an older name, and both turn up in people's notes.
    public static let schemes = ["smb", "cifs", "nfs", "afp", "ftp", "ftps", "http", "https"]

    public struct Mount: Equatable {
        /// What the filesystem was mounted from, e.g. `//sapn@server/share`.
        public let from: String
        /// Where it appears, e.g. `/Volumes/share`.
        public let on: URL

        public init(from: String, on: URL) {
            self.from = from
            self.on = on
        }
    }

    /// A share URL, or nil when this is an ordinary path.
    ///
    /// Anything without one of the known schemes is somebody's file, including
    /// a folder that happens to have a colon in its name.
    public static func url(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            schemes.contains(scheme),
            url.host != nil
        else { return nil }
        return url
    }

    /// Where this share already is, if it is already there.
    ///
    /// Mounting something that is mounted produces a second mount point with a
    /// number on the end, which is how people end up with `share-1` through
    /// `share-4` and no idea which is which.
    public static func existingMount(for url: URL, in mounts: [Mount]) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }
        let wanted = share(from: url.path)

        return mounts.first { mount in
            guard let source = networkSource(mount.from), source.host == host else { return false }
            guard let wanted, !wanted.isEmpty else { return true }
            return source.share == wanted
        }?.on
    }

    /// Splits a mount source into server and share, or nil when it is not a
    /// network filesystem at all.
    ///
    /// Two shapes, and the difference matters: `//server/share` for SMB and
    /// AFP, `server:/export` for NFS. Anything else is a local device, and a
    /// local device is never a share however much `/dev/disk1s1` may look like
    /// one when you squint at it as `host/share`.
    public static func networkSource(_ from: String) -> (host: String, share: String?)? {
        if from.hasPrefix("//") {
            let body = String(from.dropFirst(2))
            // The user part is not ours to match on: the same share mounted by
            // a different account is still the same share.
            let withoutUser = body.split(separator: "@").last.map(String.init) ?? body
            let parts = withoutUser.split(separator: "/", maxSplits: 1).map(String.init)
            guard let host = parts.first, !host.isEmpty else { return nil }
            return (host.lowercased(), parts.dropFirst().first.flatMap(share(from:)))
        }

        if !from.hasPrefix("/"), let colon = from.firstIndex(of: ":") {
            let host = String(from[..<colon]).lowercased()
            guard !host.isEmpty else { return nil }
            return (host, share(from: String(from[from.index(after: colon)...])))
        }

        return nil
    }

    /// Normalises a share or export path so the two spellings can be compared.
    private static func share(from path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Every mounted filesystem, as the kernel sees it.
    public static func currentMounts() -> [Mount] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }

        return (0..<Int(count)).map { index in
            var entry = buffer[index]
            return Mount(
                from: string(from: &entry.f_mntfromname),
                on: URL(fileURLWithPath: string(from: &entry.f_mntonname), isDirectory: true)
            )
        }
    }

    /// statfs gives fixed-size C char arrays, which Swift imports as tuples.
    private static func string<T>(from tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self, capacity: MemoryLayout<T>.size
            ) { String(cString: $0) }
        }
    }
}
