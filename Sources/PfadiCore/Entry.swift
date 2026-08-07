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
    public let cloud: CloudFiles.Status

    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        size: Int64?,
        modified: Date?,
        created: Date? = nil,
        cloud: CloudFiles.Status = .local
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.created = created
        self.cloud = cloud
    }
}
