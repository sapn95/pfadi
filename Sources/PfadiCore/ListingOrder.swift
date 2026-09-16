import Foundation

/// What the list is sorted by.
///
/// Not `SortOrder`: Foundation has one of those now, and a second type by that
/// name in scope makes every mention of it ambiguous.
public struct ListingOrder: Equatable, Sendable {
    public enum Key: String, Sendable, CaseIterable {
        case name
        case size
        case modified
        case created
        case added
        case opened
        case kind
        case fileExtension = "extension"
        case tags
        case permissions
        case owner
    }

    public var key: Key
    public var ascending: Bool

    public init(key: Key, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    public static let byName = ListingOrder(key: .name, ascending: true)

    /// Newest first, which is what a folder is usually opened to find out.
    public static let byNewest = ListingOrder(key: .modified, ascending: false)
}

extension DirectoryListing {
    /// Sorts a listing.
    ///
    /// Folders are sorted among the files rather than held above them, under
    /// every column including the name one. The convention every other file
    /// browser follows answers a question nobody asked: sorted by name you want
    /// the alphabet, and a block of folders in front of it means reading the
    /// list twice to find a name you already know. Sorted by date you want what
    /// has just changed, and forty folders on top hide it.
    ///
    /// - Parameter sizeOf: what a row's size is, when that is not simply the
    ///   number the filesystem gave. A folder has no size on disk, so sorting
    ///   by size left every folder compared equal and sitting in name order,
    ///   which looks exactly like a sort that does not work. Passing the
    ///   measured sizes in puts them where their contents say. A folder nobody
    ///   has measured yet sorts last either way up, because unknown is not
    ///   zero.
    public static func sorted(
        _ entries: [Entry],
        by order: ListingOrder,
        sizeOf: ((Entry) -> Int64?)? = nil
    ) -> [Entry] {
        entries.sorted { lhs, rhs in
            // Answered here rather than in `compare`, and deliberately not
            // flipped with the column: a row whose size nobody knows yet
            // belongs at the bottom whichever way the arrow points. A comparison cannot say that, because the switch below
            // turns it upside down along with everything else.
            if order.key == .size {
                let left = size(of: lhs, using: sizeOf)
                let right = size(of: rhs, using: sizeOf)
                if left == nil || right == nil {
                    guard left != nil || right != nil else {
                        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    }
                    return right == nil
                }
            }

            switch compare(lhs, rhs, by: order.key, sizeOf: sizeOf) {
            case .orderedSame:
                // A stable tiebreak, so two files of the same size do not swap
                // places every time the folder is re-read.
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .orderedAscending:
                return order.ascending
            case .orderedDescending:
                return !order.ascending
            }
        }
    }

    private static func compare(
        _ lhs: Entry,
        _ rhs: Entry,
        by key: ListingOrder.Key,
        sizeOf: ((Entry) -> Int64?)?
    ) -> ComparisonResult {
        switch key {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .size:
            // Both sides are known by the time this runs: `sorted` deals with
            // the unknown ones before it gets here.
            let left = size(of: lhs, using: sizeOf) ?? 0
            let right = size(of: rhs, using: sizeOf) ?? 0
            if left == right { return .orderedSame }
            return left < right ? .orderedAscending : .orderedDescending
        case .modified:
            return compare(lhs.modified, rhs.modified)
        case .created:
            return compare(lhs.created, rhs.created)
        case .added:
            return compare(lhs.added, rhs.added)
        case .opened:
            return compare(lhs.opened, rhs.opened)
        case .kind:
            return compare(lhs.kind, rhs.kind)
        case .fileExtension:
            return compare(lhs.url.pathExtension, rhs.url.pathExtension)
        case .tags:
            // Joined rather than compared element by element: what is on screen
            // is one string, and sorting by something the eye cannot see in the
            // column is worse than sorting by nothing.
            return compare(lhs.tags.joined(separator: ", "), rhs.tags.joined(separator: ", "))
        case .permissions:
            return compare(lhs.permissions, rhs.permissions)
        case .owner:
            return compare(lhs.owner, rhs.owner)
        }
    }

    /// Text, with the empty ones last either way up handled by the caller.
    ///
    /// A row with nothing in the column sorts as an empty string, which puts it
    /// at the top of an A-to-Z sort. That is the right place for it: the column
    /// is empty, and it is honest for the empties to be together.
    private static func compare(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        (lhs ?? "").localizedStandardCompare(rhs ?? "")
    }

    /// An entry whose date could not be read sorts as the oldest thing there
    /// is, rather than jumping to the top of a newest-first list.
    private static func compare(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        let left = lhs ?? .distantPast
        let right = rhs ?? .distantPast
        if left == right { return .orderedSame }
        return left < right ? .orderedAscending : .orderedDescending
    }

    /// How big a row is: what the caller says, or what the filesystem said.
    ///
    /// A folder's own entry has no size, so without a resolver every folder is
    /// nil here, and that is exactly what made sorting by size look broken.
    private static func size(of entry: Entry, using sizeOf: ((Entry) -> Int64?)?) -> Int64? {
        if let sizeOf { return sizeOf(entry) }
        return entry.size
    }
}
