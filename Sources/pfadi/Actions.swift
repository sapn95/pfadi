import AppKit

/// The three things a person reaches for after finding a file: its path on the
/// clipboard, a shell in that folder, or the same folder in Finder.
enum Actions {
    /// Puts a path on the general pasteboard.
    static func copyPath(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Both flavours: the string for a shell, the URL for anything that
        // would rather have a file reference than eleven characters of text.
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(url.path, forType: .string)
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
