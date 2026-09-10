import Foundation
import PfadiCore

enum SortingSuites {
    static func run() {
        let folder = Entry(
            url: URL(fileURLWithPath: "/x/folder"), name: "folder", isDirectory: true,
            size: nil, modified: Date(timeIntervalSince1970: 0))
        let small = Entry(
            url: URL(fileURLWithPath: "/x/small.txt"), name: "small.txt", isDirectory: false,
            size: 10, modified: Date(timeIntervalSince1970: 300))
        let big = Entry(
            url: URL(fileURLWithPath: "/x/big.txt"), name: "big.txt", isDirectory: false,
            size: 9000, modified: Date(timeIntervalSince1970: 100))
        let unknown = Entry(
            url: URL(fileURLWithPath: "/x/unknown.txt"), name: "unknown.txt", isDirectory: false,
            size: nil, modified: nil)
        let all = [small, big, folder, unknown]

        Harness.suite("sorting: folders stay on top under the name column") {
            for ascending in [true, false] {
                let sorted = DirectoryListing.sorted(
                    all, by: ListingOrder(key: .name, ascending: ascending))
                Harness.expectEqual(
                    sorted.first?.name, "folder",
                    "name \(ascending ? "up" : "down") keeps the folder first")
            }
        }

        Harness.suite("sorting: and are sorted among the files everywhere else") {
            // The complaint this answers: newest first with the folders pinned
            // above the files shows every folder before the newest thing in
            // the folder, which is the one row that was being asked for.
            for key in ListingOrder.Key.allCases where key != .name {
                for ascending in [true, false] {
                    let order = ListingOrder(key: key, ascending: ascending)
                    // Against the same sort with grouping explicitly off, which
                    // is the question being asked. Comparing against a name is
                    // not: under the extension column a folder has none, so it
                    // sorts first on its own merits and looks pinned.
                    Harness.expectEqual(
                        DirectoryListing.sorted(all, by: order).map(\.name),
                        DirectoryListing.sorted(all, by: order, groupingFolders: false)
                            .map(\.name),
                        "\(key.rawValue) \(ascending ? "up" : "down") sorts it among the files")
                }
            }
        }

        Harness.suite("sorting: the name column is the only one that groups them") {
            Harness.expect(ListingOrder.byName.groupsFolders, "name groups")
            for key in ListingOrder.Key.allCases where key != .name {
                Harness.expect(
                    !ListingOrder(key: key, ascending: true).groupsFolders,
                    "\(key.rawValue) does not")
            }
            // The override the filter uses, which has to win over the column.
            Harness.expectEqual(
                DirectoryListing.sorted(all, by: .byName, groupingFolders: false).first?.name,
                "big.txt",
                "and it can be turned off for a column that would group")
        }

        Harness.suite("sorting: by size") {
            // The folder has no size of its own here, so it sorts with the
            // rows nobody has measured: unknown is not zero, either way up.
            let up = DirectoryListing.sorted(all, by: ListingOrder(key: .size, ascending: true))
            Harness.expectEqual(
                up.map(\.name), ["small.txt", "big.txt", "folder", "unknown.txt"],
                "smallest first, and a size nobody knows sorts last rather than as zero")

            let down = DirectoryListing.sorted(all, by: ListingOrder(key: .size, ascending: false))
            Harness.expectEqual(
                down.map(\.name), ["big.txt", "small.txt", "folder", "unknown.txt"],
                "and the other way round")
        }

        Harness.suite("sorting: by date") {
            let newest = DirectoryListing.sorted(
                all, by: ListingOrder(key: .modified, ascending: false))
            Harness.expectEqual(
                newest.map(\.name), ["small.txt", "big.txt", "folder", "unknown.txt"],
                "newest first, folder and all, and an unreadable date sinks rather than floats")
        }

        Harness.suite("sorting: by name is still number-aware") {
            let entries = ["img10.png", "img2.png", "img1.png"].map {
                Entry(
                    url: URL(fileURLWithPath: "/x/\($0)"), name: $0, isDirectory: false,
                    size: 1, modified: nil)
            }
            Harness.expectEqual(
                DirectoryListing.sorted(entries, by: .byName).map(\.name),
                ["img1.png", "img2.png", "img10.png"],
                "img2 before img10")
        }

        Harness.suite("sorting: equal values fall back to the name") {
            let a = Entry(
                url: URL(fileURLWithPath: "/x/a"), name: "a", isDirectory: false, size: 5,
                modified: nil)
            let b = Entry(
                url: URL(fileURLWithPath: "/x/b"), name: "b", isDirectory: false, size: 5,
                modified: nil)
            // Without a tiebreak, two files of the same size swap places every
            // time the folder is re-read, which the watcher does constantly.
            Harness.expectEqual(
                DirectoryListing.sorted([b, a], by: ListingOrder(key: .size, ascending: true))
                    .map(\.name),
                ["a", "b"],
                "same size, so the name decides")
        }

        Harness.suite("preferences: the sort order survives a quit") {
            let store = MemorySortStore()
            let first = Preferences(store: store)
            Harness.expectEqual(first.sortOrder, .byNewest, "newest first by default")

            // Back to front from the default, so this cannot pass by reading
            // the default twice: ascending has to survive as well as the key.
            first.sortOrder = .byName
            Harness.expectEqual(
                Preferences(store: store).sortOrder, .byName,
                "and comes back on the next launch")
        }

        Harness.suite("preferences: a nonsense column falls back") {
            let store = MemorySortStore()
            store.set("colour", forKey: "sortKey")
            // A key written by a future version, or by somebody with a plist
            // editor, must not leave the list unsorted.
            Harness.expectEqual(
                Preferences(store: store).sortOrder.key, ListingOrder.byNewest.key,
                "an unknown column becomes the default one")
        }
    }
}

private final class MemorySortStore: KeyValueStore {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) {
        if let value { values[key] = value } else { values.removeValue(forKey: key) }
    }
}
