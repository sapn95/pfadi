import Foundation

/// Which `Pfadi.app` a command line tool should open.
///
/// The commands and the application are installed together and can still end up
/// apart. LaunchServices is asked first, so that an application moved somewhere
/// of its own is still found, and LaunchServices answers with whatever it saw
/// last: on a machine where the project is also built from source, that is the
/// copy in `build/`, which is how `pfadi --version` came to print 0.41.0 and
/// open 0.40.0.
///
/// The way out is not to stop asking LaunchServices but to notice the
/// disagreement. A command knows which version it is, and the bundle that
/// belongs to it carries the same one.
public enum BundleChoice {
    /// The places `Pfadi.app` is installed, in the order they should be tried.
    ///
    /// Homebrew first, because that is how it arrives, and the build directory
    /// last, because a from-source build is the one case where somebody knows
    /// what they are doing.
    public static func installedLocations(
        home: String = NSHomeDirectory(),
        workingDirectory: String = FileManager.default.currentDirectoryPath
    ) -> [URL] {
        [
            "/opt/homebrew/opt/pfadi/Pfadi.app",
            "/usr/local/opt/pfadi/Pfadi.app",
            "/Applications/Pfadi.app",
            home + "/Applications/Pfadi.app",
            workingDirectory + "/build/Pfadi.app",
        ].map { URL(fileURLWithPath: $0) }
    }

    /// The version of a bundle on disk, or nil when it does not say.
    public static func version(of bundle: URL) -> String? {
        Bundle(url: bundle)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// The bundle to open out of everything that was found.
    ///
    /// The first one whose version is the version of the command asking, and
    /// failing that the first one there is. Never nothing when there was
    /// something: a bundle that does not say which version it is still opens,
    /// and reporting no application at all because of a missing Info.plist key
    /// would be a worse answer than an old window.
    public static func pick(
        from candidates: [URL],
        matching version: String,
        versionOf: (URL) -> String? = BundleChoice.version(of:)
    ) -> URL? {
        candidates.first { versionOf($0) == version } ?? candidates.first
    }
}
