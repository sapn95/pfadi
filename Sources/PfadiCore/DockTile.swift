import Foundation

/// Keeping pfadi in the Dock across a `brew upgrade`.
///
/// Homebrew installs into a path with the version in it, so the Dock ends up
/// holding `…/Cellar/pfadi/0.36.0/Pfadi.app`. The next upgrade deletes that
/// folder and the tile becomes a question mark that has to be dragged in again,
/// every single time.
///
/// Pointing the tile at the stable `…/opt/pfadi/Pfadi.app` symlink instead does
/// not help, and that was measured rather than assumed: the Dock rewrote the
/// entry back to the resolved Cellar path the moment the application ran. It
/// stores where the running bundle actually is, so there is nothing to point at
/// that stays still.
///
/// What is left is to repair it, and to do that at the one moment when the new
/// path is known and the old one has not been clicked yet: when a running pfadi
/// notices that the installed version is no longer the one it is.
public enum DockTile {
    /// The Dock's own preference domain, read and written the way it expects.
    ///
    /// Through CFPreferences rather than by editing the file. `cfprefsd` holds
    /// the Dock's settings in memory and writes them out when it feels like it,
    /// so a file edited underneath it is overwritten by whatever was cached.
    public static let domain = "com.apple.dock"
    static let key = "persistent-apps"

    /// What to do with the list of tiles that is already there.
    public enum Placement: Equatable {
        /// It is already pointing at this bundle.
        case alreadyThere
        /// One of the tiles is a pfadi that has moved, at this index.
        case replace(Int)
        /// There is no pfadi tile at all.
        case append
    }

    /// How a bundle is written into a tile.
    ///
    /// Percent-encoded with a trailing slash, which is the spelling the Dock
    /// uses for every other tile in the file. Writing a bare path there gives a
    /// tile that draws and cannot be clicked.
    public static func urlString(for bundle: URL) -> String {
        var path = bundle.standardizedFileURL.path
        if !path.hasSuffix("/") { path += "/" }
        return URL(fileURLWithPath: path).absoluteString
    }

    /// Whether a tile is one of ours, wherever it points.
    ///
    /// By bundle name rather than by path, because the path is exactly the
    /// thing that has changed. Both the application and the launcher
    /// `pfadi-default` writes are called `Pfadi.app`.
    public static func isPfadi(_ urlString: String) -> Bool {
        URL(string: urlString)?.standardizedFileURL.lastPathComponent.lowercased()
            == "pfadi.app"
    }

    /// What should happen to `tiles` so that pfadi sits at `bundle`.
    public static func placement(of tiles: [String], bundle: URL) -> Placement {
        let wanted = urlString(for: bundle)
        if let index = tiles.firstIndex(where: { isPfadi($0) }) {
            return tiles[index] == wanted ? .alreadyThere : .replace(index)
        }
        return .append
    }

    /// A tile, in the shape the Dock's own file uses.
    public static func tile(for bundle: URL) -> [String: Any] {
        [
            "GUID": Int.random(in: 1_000_000...9_999_999),
            "tile-type": "file-tile",
            "tile-data": [
                "file-label": bundle.deletingPathExtension().lastPathComponent,
                "file-type": 41,
                "file-data": [
                    "_CFURLString": urlString(for: bundle),
                    "_CFURLStringType": 15,
                ],
            ],
        ]
    }

    /// The path each tile points at, in the order the Dock draws them.
    public static func tilePaths(in apps: [[String: Any]]) -> [String] {
        apps.map { entry in
            let data = entry["tile-data"] as? [String: Any]
            let file = data?["file-data"] as? [String: Any]
            return file?["_CFURLString"] as? String ?? ""
        }
    }

    /// The same tiles with pfadi pointing at `bundle`, or nothing when it
    /// already does.
    public static func updated(
        _ apps: [[String: Any]],
        toPointAt bundle: URL
    ) -> [[String: Any]]? {
        var apps = apps
        switch placement(of: tilePaths(in: apps), bundle: bundle) {
        case .alreadyThere:
            return nil
        case .replace(let index):
            // A fresh tile rather than an edited one. The old entry carries a
            // bookmark of the folder that has just been deleted, and a tile
            // holding both opens the wrong thing.
            apps[index] = tile(for: bundle)
        case .append:
            apps.append(tile(for: bundle))
        }
        return apps
    }

    /// What happened when the tile was asked to point somewhere.
    public enum Outcome: Equatable {
        case alreadyThere
        case repaired
        case added
        case refused
    }

    /// Points the Dock's pfadi tile at `bundle`, adding one if there is none.
    ///
    /// The Dock is restarted afterwards, because it reads this once at launch
    /// and never again. That costs a redraw and nothing else: the Dock comes
    /// straight back and no window is touched.
    /// - Parameter repairingOnly: leave the Dock alone when there is no pfadi
    ///   tile at all. Putting itself in somebody's Dock because it happened to
    ///   be started is not something an application gets to do; fixing a tile
    ///   they already asked for is.
    @discardableResult
    public static func point(
        at bundle: URL,
        repairingOnly: Bool = false,
        restarting: Bool = true
    ) -> Outcome {
        let existing =
            CFPreferencesCopyAppValue(key as CFString, domain as CFString)
            as? [[String: Any]] ?? []
        let had = placement(of: tilePaths(in: existing), bundle: bundle)
        if repairingOnly, had == .append { return .alreadyThere }
        guard let apps = updated(existing, toPointAt: bundle) else { return .alreadyThere }

        CFPreferencesSetAppValue(key as CFString, apps as CFArray, domain as CFString)
        guard CFPreferencesAppSynchronize(domain as CFString) else { return .refused }
        if restarting { restartDock() }
        return had == .append ? .added : .repaired
    }

    private static func restartDock() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Whether the tile points at something that is no longer there.
    ///
    /// The shape an upgrade leaves behind: the folder Homebrew installed into
    /// has been deleted and the tile is a question mark.
    public static func staleTile() -> String? {
        let apps =
            CFPreferencesCopyAppValue(key as CFString, domain as CFString)
            as? [[String: Any]] ?? []
        return tilePaths(in: apps).first {
            isPfadi($0) && !FileManager.default.fileExists(atPath: path(of: $0) ?? "")
        }
    }

    /// The plain path inside a tile's URL string.
    public static func path(of urlString: String) -> String? {
        URL(string: urlString)?.standardizedFileURL.path
    }
}
