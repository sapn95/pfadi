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

        Harness.suite("sorting: folders stay on top whatever the column") {
            for key in ListingOrder.Key.allCases {
                for ascending in [true, false] {
                    let sorted = DirectoryListing.sorted(
                        all, by: ListingOrder(key: key, ascending: ascending))
                    Harness.expectEqual(
                        sorted.first?.name, "folder",
                        "\(key.rawValue) \(ascending ? "up" : "down") keeps the folder first")
                }
            }
        }

        Harness.suite("sorting: by size") {
            let up = DirectoryListing.sorted(all, by: ListingOrder(key: .size, ascending: true))
            Harness.expectEqual(
                up.map(\.name), ["folder", "small.txt", "big.txt", "unknown.txt"],
                "smallest first, and a size nobody knows sorts last rather than as zero")

            let down = DirectoryListing.sorted(all, by: ListingOrder(key: .size, ascending: false))
            Harness.expectEqual(
                down.map(\.name), ["folder", "big.txt", "small.txt", "unknown.txt"],
                "and the other way round")
        }

        Harness.suite("sorting: by date") {
            let newest = DirectoryListing.sorted(
                all, by: ListingOrder(key: .modified, ascending: false))
            Harness.expectEqual(
                newest.map(\.name), ["folder", "small.txt", "big.txt", "unknown.txt"],
                "newest first, and an unreadable date sinks rather than floats")
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
            Harness.expectEqual(first.sortOrder, .byName, "name ascending by default")

            first.sortOrder = ListingOrder(key: .modified, ascending: false)
            Harness.expectEqual(
                Preferences(store: store).sortOrder,
                ListingOrder(key: .modified, ascending: false),
                "and comes back on the next launch")
        }

        Harness.suite("preferences: a nonsense column falls back") {
            let store = MemorySortStore()
            store.set("colour", forKey: "sortKey")
            // A key written by a future version, or by somebody with a plist
            // editor, must not leave the list unsorted.
            Harness.expectEqual(
                Preferences(store: store).sortOrder.key, .name, "an unknown column becomes name")
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
