import Foundation
import PfadiCore

/// The Dock tile, and why it went missing after every upgrade.
enum DockSuites {
    static func run() {
        let cellar = URL(fileURLWithPath: "/opt/homebrew/Cellar/pfadi/0.38.0/Pfadi.app")
        let older = "file:///opt/homebrew/Cellar/pfadi/0.36.0/Pfadi.app/"

        Harness.suite("dock: a tile is written the way the Dock writes them") {
            Harness.expectEqual(
                DockTile.urlString(for: cellar),
                "file:///opt/homebrew/Cellar/pfadi/0.38.0/Pfadi.app/",
                "a file URL with the trailing slash every other tile has")
            Harness.expectEqual(
                DockTile.urlString(for: URL(fileURLWithPath: "/Applications/Some App.app")),
                "file:///Applications/Some%20App.app/",
                "and a space is percent-encoded, or the tile draws and cannot be clicked")
        }

        Harness.suite("dock: ours is recognised wherever it points") {
            // By name, because the path is the thing that has changed. That is
            // the whole difficulty: the tile to repair is the one pointing at a
            // version that has been deleted.
            Harness.expect(DockTile.isPfadi(older), "an older Cellar path is one of ours")
            Harness.expect(
                DockTile.isPfadi("file:///Users/somebody/Applications/Pfadi.app/"),
                "so is the launcher in a home directory")
            Harness.expect(
                !DockTile.isPfadi("file:///Applications/Firefox.app/"),
                "and somebody else's browser is not")
        }

        Harness.suite("dock: an upgraded pfadi replaces the tile it had") {
            let tiles = ["file:///Applications/Firefox.app/", older]
            Harness.expectEqual(
                DockTile.placement(of: tiles, bundle: cellar), .replace(1),
                "the stale one is the one to rewrite, in place")
            Harness.expectEqual(
                DockTile.placement(of: [DockTile.urlString(for: cellar)], bundle: cellar),
                .alreadyThere,
                "and a tile already pointing here is left alone")
            Harness.expectEqual(
                DockTile.placement(of: ["file:///Applications/Firefox.app/"], bundle: cellar),
                .append,
                "somebody with no pfadi tile gets one only when they ask")
        }

        Harness.suite("dock: the rewritten tile keeps its place in the row") {
            let apps = [
                ["tile-data": ["file-data": ["_CFURLString": "file:///Applications/Firefox.app/"]]],
                ["tile-data": ["file-data": ["_CFURLString": older]]],
                ["tile-data": ["file-data": ["_CFURLString": "file:///Applications/iTerm.app/"]]],
            ]
            guard let updated = DockTile.updated(apps, toPointAt: cellar) else {
                Harness.expect(false, "a stale tile is something to change")
                return
            }
            Harness.expectEqual(
                DockTile.tilePaths(in: updated),
                [
                    "file:///Applications/Firefox.app/",
                    DockTile.urlString(for: cellar),
                    "file:///Applications/iTerm.app/",
                ],
                "the middle one moves, and the Dock does not get reshuffled")
            Harness.expectEqual(updated.count, 3, "and nothing is added")

            Harness.expect(
                DockTile.updated(updated, toPointAt: cellar) == nil,
                "asking again changes nothing, so the Dock is not restarted for no reason")
        }

        Harness.suite("dock: an upgrade is repaired towards what is installed") {
            // The case the repair exists for, and the one it got wrong first
            // time. After `brew upgrade` the running bundle is still the old
            // versioned path, which is also what the tile says, so repairing
            // towards what is running finds nothing to do and leaves the
            // question mark. It has to aim at what would be launched now.
            let running = URL(fileURLWithPath: "/opt/homebrew/Cellar/pfadi/0.36.0/Pfadi.app")
            let tiles = [older]
            Harness.expectEqual(
                DockTile.placement(of: tiles, bundle: running), .alreadyThere,
                "aimed at the running bundle there is nothing to do")
            Harness.expectEqual(
                DockTile.placement(of: tiles, bundle: cellar), .replace(0),
                "and aimed at the installed one there is")
        }

        Harness.suite("dock: a tile holds no leftovers from where it used to point") {
            // The old entry carries a bookmark of the folder that has just been
            // deleted. Editing the URL and keeping the rest gives a tile with
            // two answers in it.
            let apps: [[String: Any]] = [
                [
                    "GUID": 1,
                    "tile-data": [
                        "file-data": ["_CFURLString": older],
                        "bundle-identifier": "io.github.sapn95.pfadi",
                        "dock-extra": false,
                    ],
                ]
            ]
            guard let updated = DockTile.updated(apps, toPointAt: cellar),
                let data = updated[0]["tile-data"] as? [String: Any]
            else {
                Harness.expect(false, "the tile was rewritten")
                return
            }
            Harness.expect(data["bundle-identifier"] == nil, "no stale bundle identifier")
            Harness.expect(data["dock-extra"] == nil, "and nothing else left over")
            Harness.expectEqual(
                data["file-label"] as? String, "Pfadi", "with the label the Dock draws")
        }
    }
}
