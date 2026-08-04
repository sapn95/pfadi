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
    /// direction it points. Sorting by size and having folders scatter through
    /// the list is technically consistent and useless in practice: a folder has
    /// no size until something walks it, so they would all sort as zero.
    public static func sorted(_ entries: [Entry], by order: ListingOrder) -> [Entry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }

            let ascending = compare(lhs, rhs, by: order.key)
            switch ascending {
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

    private static func compare(_ lhs: Entry, _ rhs: Entry, by key: ListingOrder.Key)
        -> ComparisonResult
    {
        switch key {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .size:
            let left = lhs.size ?? 0
            let right = rhs.size ?? 0
            if left == right { return .orderedSame }
            return left < right ? .orderedAscending : .orderedDescending
        case .modified:
            // An entry whose date could not be read sorts as the oldest thing
            // there is, rather than jumping to the top of a newest-first list.
            let left = lhs.modified ?? .distantPast
            let right = rhs.modified ?? .distantPast
            if left == right { return .orderedSame }
            return left < right ? .orderedAscending : .orderedDescending
        }
    }
}
