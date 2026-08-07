import Foundation
import PfadiCore

/// Sorting once folders have sizes, and trashing things macOS will not trash.
enum OrderAndTrashSuites {
    static func run() {
        sorting()
        trashing()
    }

    private static func entry(
        _ name: String,
        isDirectory: Bool = false,
        size: Int64? = nil,
        modified: Date? = nil,
        created: Date? = nil
    ) -> Entry {
        Entry(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            isDirectory: isDirectory,
            size: size,
            modified: modified,
            created: created)
    }

    private static func sorting() {
        Harness.suite("sorting: folders stay above files whichever way it points") {
            let listing = [
                entry("zebra", isDirectory: true), entry("apple", size: 10),
            ]
            for ascending in [true, false] {
                let sorted = DirectoryListing.sorted(
                    listing, by: ListingOrder(key: .size, ascending: ascending))
                Harness.expectEqual(
                    sorted.first?.name, "zebra",
                    "the folder is first with ascending \(ascending)")
            }
        }

        Harness.suite("sorting: folders sort by the size somebody measured") {
            // The bug exactly: a folder's own entry has no size, so without the
            // measured ones every folder compared equal and stayed in name
            // order, which looks like a sort that does nothing.
            let listing = [
                entry("big", isDirectory: true), entry("small", isDirectory: true),
            ]
            let measured: [String: Int64] = ["big": 9_000, "small": 10]

            let plain = DirectoryListing.sorted(
                listing, by: ListingOrder(key: .size, ascending: true))
            Harness.expectEqual(
                plain.map(\.name), ["big", "small"],
                "with no measurements they fall back to name order")

            let withSizes = DirectoryListing.sorted(
                listing, by: ListingOrder(key: .size, ascending: true)
            ) { measured[$0.name] }
            Harness.expectEqual(
                withSizes.map(\.name), ["small", "big"], "smallest first once measured")

            let descending = DirectoryListing.sorted(
                listing, by: ListingOrder(key: .size, ascending: false)
            ) { measured[$0.name] }
            Harness.expectEqual(
                descending.map(\.name), ["big", "small"], "and largest first the other way")
        }

        Harness.suite("sorting: a folder not measured yet goes last either way up") {
            // Not treated as zero. A folder still being walked would otherwise
            // sit at the top of a smallest-first list and jump the moment its
            // answer arrived.
            let listing = [
                entry("known", isDirectory: true), entry("unknown", isDirectory: true),
            ]
            let measured: [String: Int64] = ["known": 500]

            for ascending in [true, false] {
                let sorted = DirectoryListing.sorted(
                    listing, by: ListingOrder(key: .size, ascending: ascending)
                ) { measured[$0.name] }
                Harness.expectEqual(
                    sorted.map(\.name), ["known", "unknown"],
                    "measured above unmeasured with ascending \(ascending)")
            }
        }

        Harness.suite("sorting: created is its own column, not modified again") {
            let old = Date(timeIntervalSince1970: 1_000)
            let recent = Date(timeIntervalSince1970: 2_000_000)
            // Made first, changed last, and the other way round, so a sort that
            // quietly used the wrong date cannot pass.
            let listing = [
                entry("first-made", size: 1, modified: recent, created: old),
                entry("last-made", size: 2, modified: old, created: recent),
            ]
            Harness.expectEqual(
                DirectoryListing.sorted(listing, by: ListingOrder(key: .created, ascending: true))
                    .map(\.name),
                ["first-made", "last-made"],
                "oldest creation first")
            Harness.expectEqual(
                DirectoryListing.sorted(listing, by: ListingOrder(key: .modified, ascending: true))
                    .map(\.name),
                ["last-made", "first-made"],
                "and modified really is a different order")
        }

        Harness.suite("sorting: a missing date is the oldest thing there is") {
            let listing = [
                entry("dated", size: 1, created: Date(timeIntervalSince1970: 5_000)),
                entry("undated", size: 2, created: nil),
            ]
            Harness.expectEqual(
                DirectoryListing.sorted(listing, by: ListingOrder(key: .created, ascending: true))
                    .map(\.name),
                ["undated", "dated"],
                "rather than jumping to the top of a newest-first list")
        }

        Harness.suite("sorting: every column has a key that survives a round trip") {
            // The preference stores the raw value. A key that cannot be read
            // back silently resets the sort to name on the next launch.
            for key in ListingOrder.Key.allCases {
                Harness.expectEqual(
                    ListingOrder.Key(rawValue: key.rawValue), key, "\(key.rawValue) round trips")
            }
        }
    }

    private static func trashing() {
        Harness.suite("trash: an ordinary file really goes") {
            try withSandbox(["gone.txt"]) { root in
                let file = root.appendingPathComponent("gone.txt")
                let outcome = FileOperations.trashChecking(file)
                switch outcome {
                case .moved(let landed):
                    Harness.expect(
                        !FileManager.default.fileExists(atPath: file.path),
                        "and is no longer where it was")
                    if let landed {
                        try? FileManager.default.removeItem(at: landed)
                    }
                case .refused(let reason):
                    Harness.expect(false, "a file in a temporary folder should go: \(reason)")
                }
            }
        }

        Harness.suite("trash: something that is not there is refused, not claimed") {
            let missing = URL(fileURLWithPath: "/nope-\(UUID().uuidString)")
            // Refused specifically, not merely "not one particular success":
            // a .moved with a destination would have slipped through that.
            guard case .refused = FileOperations.trashChecking(missing) else {
                Harness.expect(false, "there was nothing to move, so it cannot have moved")
                return
            }
            Harness.expect(true, "there was nothing to move")
        }

        Harness.suite("trash: the folders macOS keeps are recognised") {
            let home = URL(fileURLWithPath: "/Users/somebody")
            for name in ["Documents", "Desktop", "Library", "Downloads", "Pictures", "Public"] {
                Harness.expect(
                    FileOperations.isReservedHomeFolder(
                        home.appendingPathComponent(name), home: home),
                    "~/\(name) is one of them")
            }
        }

        Harness.suite("trash: only directly inside home, and only by that name") {
            let home = URL(fileURLWithPath: "/Users/somebody")
            Harness.expect(
                !FileOperations.isReservedHomeFolder(
                    home.appendingPathComponent("projects/Documents"), home: home),
                "a folder called Documents somewhere else is an ordinary folder")
            Harness.expect(
                !FileOperations.isReservedHomeFolder(
                    home.appendingPathComponent("notes"), home: home),
                "and an ordinary name is not reserved")
            Harness.expect(
                !FileOperations.isReservedHomeFolder(
                    URL(fileURLWithPath: "/Users/somebody-else/Documents"), home: home),
                "nor is somebody else's")
            for name in ["Applications", "Sites"] {
                Harness.expect(
                    !FileOperations.isReservedHomeFolder(
                        home.appendingPathComponent(name), home: home),
                    "~/\(name) is a folder people make themselves, not one of Apple's")
            }
        }
    }
}
