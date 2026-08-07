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
    }

    public var key: Key
    public var ascending: Bool

    public init(key: Key, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    public static let byName = ListingOrder(key: .name, ascending: true)
}

extension DirectoryListing {
    /// Sorts a listing.
    ///
    /// Directories stay above files whatever the column and whichever
    /// direction it points, which is the convention every file browser on this
    /// system follows.
    ///
    /// - Parameter sizeOf: what a row's size is, when that is not simply the
    ///   number the filesystem gave. A folder has no size on disk, so sorting
    ///   by size used to leave every folder pinned to the top in name order —
    ///   which looks exactly like a sort that does not work. Passing the
    ///   measured sizes in sorts the folders among themselves too. Folders that
    ///   have not been measured yet sort last within their block, because
    ///   unknown is not zero.
    public static func sorted(
        _ entries: [Entry],
        by order: ListingOrder,
        sizeOf: ((Entry) -> Int64?)? = nil
    ) -> [Entry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }

            // Answered here rather than in `compare`, and deliberately not
            // flipped with the column: a row whose size nobody knows yet
            // belongs at the bottom of its block whichever way the arrow
            // points. A comparison cannot say that, because the switch below
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
        }
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
