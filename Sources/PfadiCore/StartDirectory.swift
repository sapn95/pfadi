import Foundation

/// Decides which folder a new window opens in.
///
/// Four sources disagree, so the order they win in has to be written down
/// somewhere rather than spread across the app delegate.
public enum StartDirectory {
    /// - Parameters:
    ///   - explicit: a folder passed on the command line or dropped on the icon.
    ///     Always wins: it is the most recent thing the person said.
    ///   - workingDirectory: the shell's directory. A launched `.app` inherits
    ///     `/`, so that value means "nobody asked for anything" rather than root.
    ///   - remembered: where the last window was, if it still exists.
    public static func choose(
        explicit: URL?,
        workingDirectory: URL,
        remembered: String?,
        home: URL,
        fileManager: FileManager = .default
    ) -> URL {
        if let explicit, isDirectory(explicit, fileManager) {
            return PathCompletion.directoryURL(explicit)
        }
        if workingDirectory.path != "/", isDirectory(workingDirectory, fileManager) {
            return PathCompletion.directoryURL(workingDirectory)
        }
        if let remembered, !remembered.isEmpty {
            let url = URL(fileURLWithPath: remembered)
            // The folder may have been deleted, renamed or unmounted since the
            // last launch. Falling back beats opening onto an error.
            if isDirectory(url, fileManager) {
                return PathCompletion.directoryURL(url)
            }
        }
        return PathCompletion.directoryURL(home)
    }

    private static func isDirectory(_ url: URL, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
