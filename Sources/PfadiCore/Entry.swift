import Foundation

/// One row in the file list.
///
/// Deliberately a value type with no icon in it: an icon costs a synchronous
/// round trip to the system, so it is fetched per visible row instead of once
/// per directory entry. A directory with 40k files would otherwise stall.
public struct Entry: Sendable, Equatable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let size: Int64?
    public let modified: Date?
    /// When it was made. Optional because not every filesystem records one:
    /// an SMB share can answer with nothing at all.
    public let created: Date?
    /// When it arrived in this folder, which is not when it was made.
    public let added: Date?
    public let opened: Date?
    /// What the system calls it: "Folder", "PNG image".
    public let kind: String?
    /// Finder's tags, in the order Finder keeps them.
    public let tags: [String]
    /// `drwxr-xr-x`, from lstat rather than through the resource keys, which
    /// follow symbolic links.
    public let permissions: String?
    public let owner: String?
    public let cloud: CloudFiles.Status

    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        size: Int64?,
        modified: Date?,
        created: Date? = nil,
        added: Date? = nil,
        opened: Date? = nil,
        kind: String? = nil,
        tags: [String] = [],
        permissions: String? = nil,
        owner: String? = nil,
        cloud: CloudFiles.Status = .local
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.created = created
        self.added = added
        self.opened = opened
        self.kind = kind
        self.tags = tags
        self.permissions = permissions
        self.owner = owner
        self.cloud = cloud
    }
}
