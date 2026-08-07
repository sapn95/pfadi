import Foundation

/// A column the file list can show.
///
/// The set is deliberately wider than the four that started here, and only the
/// ones switched on are read off the disk. That is the whole reason this is a
/// type rather than a handful of fields: asking the filesystem for tags, owner
/// and permissions costs something per entry, and a folder of forty thousand
/// files should not pay it for a column nobody has on.
public enum ListingColumn: String, CaseIterable, Sendable {
    case name
    case size
    case modified
    case created
    /// When it arrived here, which is not when it was made. In a downloads
    /// folder it is the only date that means anything.
    case added
    case opened
    /// What the system calls it: "Folder", "PNG image", "Terminal script".
    case kind
    case fileExtension = "extension"
    /// Finder's coloured tags.
    case tags
    /// `drwxr-xr-x`. Finder cannot show this at all, and for anybody who also
    /// lives in a terminal it is the column they miss most.
    case permissions
    case owner
    /// How many files are inside, from the same walk that measures the size.
    case files

    /// The heading.
    public var title: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .modified: return "Modified"
        case .created: return "Created"
        case .added: return "Added"
        case .opened: return "Last Opened"
        case .kind: return "Kind"
        case .fileExtension: return "Extension"
        case .tags: return "Tags"
        case .permissions: return "Permissions"
        case .owner: return "Owner"
        case .files: return "Files"
        }
    }

    public var width: Double {
        switch self {
        case .name: return 360
        case .size, .files: return 90
        case .modified, .created, .added, .opened: return 150
        case .kind: return 130
        case .fileExtension: return 90
        case .tags: return 120
        case .permissions: return 110
        case .owner: return 110
        }
    }

    /// Numbers read right, words read left.
    public var isRightAligned: Bool {
        switch self {
        case .size, .files: return true
        default: return false
        }
    }

    /// Name cannot be turned off. A list of sizes and dates with nothing saying
    /// which file they belong to is not a list.
    public var canBeHidden: Bool { self != .name }

    /// The three that are on for somebody who has never touched the settings.
    public static let byDefault: [ListingColumn] = [.name, .size, .modified]

    /// What the filesystem has to be asked for to fill this in.
    ///
    /// Empty for the ones that come from the name or from a measurement that
    /// happens elsewhere.
    public var resourceKeys: Set<URLResourceKey> {
        switch self {
        case .name, .fileExtension, .files: return []
        case .size: return [.fileSizeKey]
        case .modified: return [.contentModificationDateKey]
        case .created: return [.creationDateKey]
        case .added: return [.addedToDirectoryDateKey]
        case .opened: return [.contentAccessDateKey]
        case .kind: return [.localizedTypeDescriptionKey]
        case .tags: return [.tagNamesKey]
        // Read with lstat rather than through URLResourceValues: the resource
        // keys for these follow symbolic links, and the interesting thing about
        // a link is the link.
        case .permissions, .owner: return []
        }
    }

    /// Whether filling this in needs an `lstat` per entry.
    public var needsFileStatus: Bool {
        self == .permissions || self == .owner
    }

    /// The sort key this column maps to, when it can be sorted by.
    public var sortKey: ListingOrder.Key? {
        switch self {
        case .name: return .name
        case .size: return .size
        case .modified: return .modified
        case .created: return .created
        case .added: return .added
        case .opened: return .opened
        case .kind: return .kind
        case .fileExtension: return .fileExtension
        case .tags: return .tags
        case .permissions: return .permissions
        case .owner: return .owner
        // Sorting by a number that arrives after the listing does would put the
        // rows in an order and then change it under the pointer. Size is worth
        // that; a file count is not.
        case .files: return nil
        }
    }
}
