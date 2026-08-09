import Foundation

/// Whether the copy that is running is still the copy that is installed.
///
/// `brew upgrade` replaces the bundle on disk and cannot touch a process that
/// is already running — nothing can. So an application left open across an
/// upgrade goes on being the old one, silently, and the person testing the fix
/// they just installed is testing the version that had the bug.
///
/// This session hit that six times. Every one of them ended with somebody
/// saying it still does not work, which was true of what was running.
public enum InstalledVersion {
    /// Compares two dotted version strings.
    ///
    /// Numeric per component, so 0.10.0 is newer than 0.9.0 — which a string
    /// comparison gets backwards, and which is exactly the range this project
    /// is in.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = parts(of: candidate)
        let right = parts(of: current)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// The numeric parts of a version, with anything else dropped.
    ///
    /// A release candidate suffix is ignored rather than parsed: 0.33.0-rc.1
    /// compares as 0.33.0, which is close enough to decide whether to tell
    /// somebody to restart.
    private static func parts(of version: String) -> [Int] {
        version.split(separator: ".").map { component in
            Int(component.prefix { $0.isNumber }) ?? 0
        }
    }

    /// What to tell somebody, or nothing when there is nothing to tell.
    ///
    /// - Parameters:
    ///   - running: the version of the bundle this process was launched from.
    ///   - runningPath: where that bundle is.
    ///   - installed: the version of the bundle the system would launch now.
    ///   - installedPath: where that one is.
    public static func message(
        running: String,
        runningPath: String,
        installed: String?,
        installedPath: String?
    ) -> String? {
        guard let installed, let installedPath else { return nil }
        // The same bundle, upgraded underneath us or not: either way there is
        // nothing useful to say, because quitting and reopening gets the same
        // path back.
        guard installedPath != runningPath else { return nil }
        guard isNewer(installed, than: running) else { return nil }

        return "\(installed) is installed and \(running) is running — quit and reopen"
    }
}
