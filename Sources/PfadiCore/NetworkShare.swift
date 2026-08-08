import Foundation

/// Typing `smb://server/share` into the path field and having it work.
///
/// The premise of this application is that the address bar takes an address.
/// A share is an address, so it belongs in the same field rather than behind a
/// separate dialog with its own history and its own idea of what you meant.
public enum NetworkShare {
    /// What a share is called in a sidebar 170 points wide.
    ///
    /// The share name, not the host. `smb://testfiler-prod-01.filer.sigma.sbb.ch/projects`
    /// arrives on screen as `testfiler-pr…ma.sbb.ch`, which has lost both the
    /// part that says which filer and the part that says which share. The share
    /// name is short and it is what somebody was looking for; the whole address
    /// goes on the tooltip.
    public static func title(for url: URL) -> String {
        let share = url.pathComponents.first { $0 != "/" && !$0.isEmpty }
        guard let share, !share.isEmpty else {
            return url.host ?? url.absoluteString
        }
        return share.removingPercentEncoding ?? share
    }

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

    /// What was made of what somebody typed.
    public struct Interpretation: Equatable {
        public let url: URL
        /// The original text, when it had to be rewritten to get here. Nil
        /// when what was typed was already an address.
        public let rewrittenFrom: String?

        public var wasRewritten: Bool { rewrittenFrom != nil }
    }

    /// Turns what somebody typed into a share URL.
    ///
    /// People paste what their colleague sent them, and what colleagues send
    /// is `\\filer\projects` from a Windows machine, or `//filer/projects`
    /// from a Mac, or `filer:/export` from whoever set the NFS up. All three
    /// mean a place, and refusing them because of the punctuation is the
    /// application being difficult about something it can work out.
    ///
    /// With `rewriting` off, only a real address is accepted, for anybody who
    /// would rather it did exactly what they typed.
    public static func interpret(
        _ input: String,
        scheme: String,
        rewriting: Bool = true
    ) -> Interpretation? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Already an address: nothing to rewrite, whichever button is lit.
        if let direct = url(from: text) {
            return Interpretation(url: direct, rewrittenFrom: nil)
        }
        guard rewriting else { return nil }

        var body = text
        var chosen = scheme

        if body.contains("\\") {
            // A UNC path. The leading pair of backslashes is the marker, the
            // rest are separators, and SMB is the only thing it can mean.
            chosen = "smb"
            while body.hasPrefix("\\") { body.removeFirst() }
            body = body.replacingOccurrences(of: "\\", with: "/")
        } else if let colon = body.firstIndex(of: ":"), !body.hasPrefix("/"),
            !body.contains("//")
        {
            // `filer:/export`, which is how an NFS export is written down
            // everywhere except in a URL.
            chosen = "nfs"
            body = body.replacingCharacters(in: colon...colon, with: "/")
        }

        while body.hasPrefix("/") { body.removeFirst() }
        // A trailing separator is noise and produces an empty last component.
        while body.hasSuffix("/") { body.removeLast() }
        guard !body.isEmpty, schemes.contains(chosen) else { return nil }

        // Spaces and the rest are legal in a share name and illegal in a URL.
        let encoded =
            body.split(separator: "/").map { component in
                component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                    ?? String(component)
            }.joined(separator: "/")

        guard let built = url(from: "\(chosen)://\(encoded)") else { return nil }
        return Interpretation(url: built, rewrittenFrom: text)
    }

    /// The old shape, kept for callers that only want the URL.
    public static func assemble(scheme: String, from input: String) -> URL? {
        interpret(input, scheme: scheme)?.url
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
