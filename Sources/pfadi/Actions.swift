import AppKit

/// The three things a person reaches for after finding a file: its path on the
/// clipboard, a shell in that folder, or the same folder in Finder.
enum Actions {
    /// Puts a path on the general pasteboard.
    static func copyPath(_ url: URL) {
        copyPaths([url])
    }

    /// Puts several on, one per line.
    ///
    /// A line each is what a shell loop, an editor and a chat message all
    /// want. Anything cleverer — quoting, commas, a JSON array — is a guess
    /// about where they are going next.
    static func copyPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Both flavours: the string for a shell, the URLs for anything that
        // would rather have file references than a few lines of text.
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    static func showInFinder(_ url: URL) {
        showInFinder([url])
    }

    /// Hands a selection to Finder — the real one.
    ///
    /// `activateFileViewerSelecting` is the polite call, and it honours the
    /// `NSFileViewer` preference. Once `pfadi-default apply` has pointed that
    /// at pfadi, "Show in Finder" inside pfadi opened pfadi, which is a menu
    /// item that does nothing and looks like a bug.
    ///
    /// So when pfadi is the file viewer, Finder is addressed by name instead.
    /// The cost is that the item is not selected, only its folder opened:
    /// `open -R` goes through the same preference and is hijacked too, and the
    /// only route left that selects is an Apple Event, which would put a
    /// "pfadi wants to control Finder" prompt behind a menu item. Getting to
    /// Finder at the right folder is what somebody asked for; a permission
    /// dialog is not.
    /// - Parameter handled: which application took the request, for the
    ///   checks. Asking who received it is the whole question here, and it can
    ///   be answered without looking at any window — which matters, because
    ///   reading a window title needs Screen Recording permission that a CI
    ///   runner does not have and a file browser should never ask for.
    static func showInFinder(_ urls: [URL], handled: ((String?) -> Void)? = nil) {
        guard !urls.isEmpty else {
            handled?(nil)
            return
        }

        guard isFileViewer(),
            let finder = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.finder")
        else {
            // Finder is still the system's file viewer, so the polite call
            // reaches it and selects what was asked for.
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            handled?("com.apple.finder")
            return
        }

        // A folder is shown as itself; anything else as the folder holding it.
        // Deduplicated, or three files from one folder open three windows.
        var folders: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            let folder = isDirectory.boolValue ? url : url.deletingLastPathComponent()
            if !folders.contains(where: { $0.path == folder.path }) {
                folders.append(folder)
            }
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(folders, withApplicationAt: finder, configuration: configuration) {
            application, _ in
            handled?(application?.bundleIdentifier)
        }
    }

    /// Whether the system's file viewer is something other than Finder.
    ///
    /// Read every time rather than cached: `pfadi-default apply` and `undo` can
    /// change it while this is running, and a menu item that was right at
    /// launch is not good enough.
    private static func isFileViewer() -> Bool {
        let viewer =
            CFPreferencesCopyValue(
                "NSFileViewer" as CFString,
                kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? String
        guard let viewer else { return false }
        return viewer != "com.apple.finder"
    }

    /// Opens a shell in `directory`, in whichever terminal is installed.
    ///
    /// Preference order, most specialised first. Terminal.app is last because
    /// it is always present, so putting it anywhere else would mean nobody's
    /// actual terminal ever wins.
    static func openTerminal(at directory: URL) {
        let candidates = [
            "com.mitchellh.ghostty",
            "net.kovidgoyal.kitty",
            "com.googlecode.iterm2",
            "dev.warp.Warp-Stable",
            "io.alacritty",
            "com.apple.Terminal",
        ]

        let workspace = NSWorkspace.shared
        let terminal = candidates
            .lazy
            .compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }
            .first

        guard let terminal else {
            NSSound.beep()
            return
        }

        workspace.open(
            [directory],
            withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration()
        ) { application, _ in
            // The open is asynchronous, so a terminal that is present but
            // refuses to launch would otherwise fail in complete silence.
            guard application == nil else { return }
            DispatchQueue.main.async { NSSound.beep() }
        }
    }
}
