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

    static func revealInFinder(_ url: URL) {
        revealInFinder([url])
    }

    /// Hands a selection to Finder, in one window rather than one each.
    static func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
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
