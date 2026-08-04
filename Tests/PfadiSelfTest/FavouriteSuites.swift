import Foundation
import PfadiCore

enum FavouriteSuites {
    static func run() {
        Harness.suite("favourites: a first launch has the usual folders") {
            let favourites = Favourites(preferences: Preferences(store: MemoryFavouriteStore()))
            let home = FileManager.default.homeDirectoryForCurrentUser
            Harness.expect(favourites.paths.contains(home.path), "home is there")
            Harness.expect(favourites.paths.contains("/Applications"), "and Applications")
            Harness.expect(
                favourites.paths.contains(home.appendingPathComponent("Downloads").path),
                "and Downloads")
        }

        Harness.suite("favourites: adding, refusing a duplicate, removing") {
            let favourites = Favourites(preferences: Preferences(store: MemoryFavouriteStore()))
            let url = URL(fileURLWithPath: "/tmp/somewhere", isDirectory: true)

            Harness.expect(favourites.add(url), "a new folder is added")
            Harness.expect(favourites.contains(url), "and is in the list")
            Harness.expect(!favourites.add(url), "adding it twice reports that it was already in")
            Harness.expectEqual(
                favourites.paths.filter { $0 == "/tmp/somewhere" }.count, 1, "and only once")

            Harness.expect(favourites.remove(url), "removing reports success")
            Harness.expect(!favourites.contains(url), "and it is gone")
            Harness.expect(!favourites.remove(url), "removing it again reports nothing to do")
        }

        Harness.suite("favourites: an empty list is a real answer") {
            let store = MemoryFavouriteStore()
            let favourites = Favourites(preferences: Preferences(store: store))
            for path in favourites.paths {
                favourites.remove(URL(fileURLWithPath: path, isDirectory: true))
            }
            // The bug this guards: treating empty as "never set" would put the
            // defaults straight back on the next launch, so a person could
            // never clear the sidebar.
            Harness.expectEqual(
                Favourites(preferences: Preferences(store: store)).paths, [],
                "cleared stays cleared")
        }

        Harness.suite("favourites: a folder that is gone is not drawn") {
            try withSandbox(["here"], directories: ["here"]) { root in
                let favourites = Favourites(preferences: Preferences(store: MemoryFavouriteStore()))
                for path in favourites.paths {
                    favourites.remove(URL(fileURLWithPath: path, isDirectory: true))
                }
                favourites.add(root.appendingPathComponent("here"))
                favourites.add(root.appendingPathComponent("gone"))

                Harness.expectEqual(favourites.paths.count, 2, "both are remembered")
                Harness.expectEqual(
                    favourites.visible.map(\.lastPathComponent), ["here"],
                    "but only the one that exists is drawn")
            }
        }

        Harness.suite("favourites: a file is not a folder") {
            try withSandbox(["note.txt"]) { root in
                let favourites = Favourites(preferences: Preferences(store: MemoryFavouriteStore()))
                favourites.add(root.appendingPathComponent("note.txt"))
                Harness.expect(
                    !favourites.visible.contains { $0.lastPathComponent == "note.txt" },
                    "a file in the list is skipped rather than drawn as a folder")
            }
        }

        Harness.suite("favourites: home is called Home") {
            let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
            Harness.expectEqual(
                Favourites.title(for: home, home: home), "Home",
                "not the account's short name")
            Harness.expectEqual(
                Favourites.title(for: home.appendingPathComponent("git"), home: home), "git",
                "anything else is its own name")
        }
    }
}

private final class MemoryFavouriteStore: KeyValueStore {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) {
        if let value { values[key] = value } else { values.removeValue(forKey: key) }
    }
}
