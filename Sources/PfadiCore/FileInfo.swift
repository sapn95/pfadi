import Foundation

/// Everything worth saying about one item, gathered in one place.
public struct FileInfo {
    public let url: URL
    public let name: String
    public let kind: String?
    public let size: Int64?
    /// Bytes on this machine. Differs from `size` for a cloud placeholder,
    /// which reports its full size and occupies none of it.
    public let onDisk: Int64?
    public let isDirectory: Bool
    public let created: Date?
    public let modified: Date?
    public let permissions: String?
    public let owner: String?
    public let group: String?
    public let cloud: CloudFiles.Status

    public static func gather(_ url: URL, fileManager: FileManager = .default) -> FileInfo {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .localizedTypeDescriptionKey,
            // What the file actually occupies here. For a cloud placeholder
            // that is nothing, which is the honest answer to "how big is it".
            .totalFileAllocatedSizeKey,
        ]
        let values = try? url.resourceValues(forKeys: keys)
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)

        return FileInfo(
            url: url,
            name: url.lastPathComponent,
            kind: values?.localizedTypeDescription,
            size: values?.fileSize.map(Int64.init),
            onDisk: values?.totalFileAllocatedSize.map(Int64.init),
            isDirectory: values?.isDirectory ?? false,
            created: values?.creationDate,
            modified: values?.contentModificationDate,
            permissions: (attributes?[.posixPermissions] as? NSNumber)
                .map { permissionString(UInt16(truncating: $0)) },
            owner: attributes?[.ownerAccountName] as? String,
            group: attributes?[.groupOwnerAccountName] as? String,
            // Never through the File Provider: asking an extension about an
            // item is how you start downloading the thing you wanted to
            // describe.
            cloud: CloudFiles.status(of: url)
        )
    }

    /// `rwxr-xr-x`, the spelling everyone already reads without thinking.
    public static func permissionString(_ mode: UInt16) -> String {
        let bits = ["r", "w", "x"]
        return (0..<9).map { position in
            // Bit 8 is owner-read, counting down to bit 0 as other-execute.
            mode & (1 << (8 - position)) != 0 ? bits[position % 3] : "-"
        }.joined()
    }
}
