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

extension OrderAndTrashSuites {
    /// The columns, and the promise that only what is shown gets read.
    static func runColumns() {
        Harness.suite("columns: only what is on screen is read off the disk") {
            // The whole reason columns are a type. Tags, owner and permissions
            // each cost something per entry, and a folder of forty thousand
            // files should not pay for a column nobody switched on.
            Harness.expect(
                ListingColumn.name.resourceKeys.isEmpty,
                "a name needs nothing asked for")
            Harness.expect(
                ListingColumn.tags.resourceKeys.contains(.tagNamesKey),
                "tags need the tag key")
            Harness.expect(
                ListingColumn.permissions.needsFileStatus,
                "permissions need a stat rather than a resource key")
            Harness.expect(
                !ListingColumn.permissions.resourceKeys.contains(.fileSecurityKey),
                "and deliberately not the resource key, which follows symlinks")
        }

        Harness.suite("columns: everything has a title and a width") {
            for column in ListingColumn.allCases {
                Harness.expect(!column.title.isEmpty, "\(column.rawValue) has a heading")
                Harness.expect(column.width >= 80, "\(column.rawValue) is wide enough to read")
            }
        }

        Harness.suite("columns: name is the one that cannot be switched off") {
            Harness.expect(!ListingColumn.name.canBeHidden, "name stays")
            for column in ListingColumn.allCases where column != .name {
                Harness.expect(column.canBeHidden, "\(column.rawValue) can be switched off")
            }
        }

        Harness.suite("columns: a sortable column maps to a key that exists") {
            for column in ListingColumn.allCases {
                guard let key = column.sortKey else { continue }
                Harness.expect(
                    ListingOrder.Key(rawValue: key.rawValue) == key,
                    "\(column.rawValue) sorts by \(key.rawValue)")
            }
            // Files comes from a walk that finishes after the listing does.
            // Sorting by it would put the rows in an order and then change it
            // under the pointer.
            Harness.expect(ListingColumn.files.sortKey == nil, "the file count is not sortable")
        }

        Harness.suite("columns: reading fills in what was asked for") {
            try withSandbox(["note.txt", "sub"], directories: ["sub"]) { root in
                let plain = try DirectoryListing.read(
                    root, showHidden: true, columns: ListingColumn.byDefault)
                Harness.expect(
                    plain.allSatisfy { $0.permissions == nil },
                    "nothing statted when no column needs it")

                let full = try DirectoryListing.read(
                    root, showHidden: true, columns: [.name, .permissions, .owner, .kind])
                guard let folder = full.first(where: { $0.name == "sub" }),
                    let file = full.first(where: { $0.name == "note.txt" })
                else {
                    Harness.expect(false, "both entries are listed")
                    return
                }
                Harness.expect(
                    folder.permissions?.hasPrefix("d") == true,
                    "a folder reads as d..., got \(folder.permissions ?? "nothing")")
                Harness.expect(
                    file.permissions?.hasPrefix("-") == true,
                    "and a file as -..., got \(file.permissions ?? "nothing")")
                Harness.expect(
                    file.permissions?.count == 10,
                    "ten characters, like ls, got \(file.permissions?.count ?? 0)")
                Harness.expect(file.owner != nil, "and somebody owns it")
                Harness.expect(file.kind != nil, "with a kind the system named")
            }
        }

        Harness.suite("columns: a symbolic link is described as the link") {
            // The resource keys follow links. The interesting thing about a
            // link is the link, which is why this reads lstat instead.
            try withSandbox(["target.txt"]) { root in
                let link = root.appendingPathComponent("pointer")
                try FileManager.default.createSymbolicLink(
                    at: link, withDestinationURL: root.appendingPathComponent("target.txt"))

                let listed = try DirectoryListing.read(
                    root, showHidden: true, columns: [.name, .permissions])
                let found = listed.first { $0.name == "pointer" }
                Harness.expect(
                    found?.permissions?.hasPrefix("l") == true,
                    "it reads as l..., got \(found?.permissions ?? "nothing")")
            }
        }

        Harness.suite("columns: the column being sorted by is read even when hidden") {
            // A sort restored from last launch can name a column somebody has
            // since switched off. Sorting by a field that was never read puts
            // the list in an order with no explanation at all.
            try withSandbox(["b.txt", "a.txt"]) { root in
                let listed = try DirectoryListing.read(
                    root,
                    showHidden: true,
                    order: ListingOrder(key: .created, ascending: true),
                    columns: [.name])
                Harness.expect(
                    listed.allSatisfy { $0.created != nil },
                    "the creation dates are there despite the column being off")
            }
        }
    }
}
