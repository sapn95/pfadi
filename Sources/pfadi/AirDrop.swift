import AppKit

/// Sending files to a Mac or a phone nearby, the way Finder does.
///
/// Two ways in, the same two Finder has: a row in the sidebar that opens the
/// AirDrop window and takes files dropped on it, and an item in the File and
/// right-click menus that sends whatever is selected.
enum AirDrop {
    /// Finder's own AirDrop window, which is a small application of its own.
    ///
    /// Opened rather than rebuilt: the list of who is nearby and whether they
    /// can be seen is the system's, and there is no public way to draw it.
    static let window = URL(
        fileURLWithPath:
            "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")

    private static var service: NSSharingService? {
        NSSharingService(named: .sendViaAirDrop)
    }

    /// Whether these can go over AirDrop at all.
    ///
    /// No, when AirDrop is switched off or the Mac has no radio for it, which
    /// is the answer the system gives and the one worth passing on.
    static func canSend(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty, let service else { return false }
        return service.canPerform(withItems: urls)
    }

    /// Opens the sheet that asks who to send them to.
    @discardableResult
    static func send(_ urls: [URL]) -> Bool {
        guard canSend(urls), let service else { return false }
        service.perform(withItems: urls)
        return true
    }

    /// Brings up the AirDrop window, or says it cannot.
    @discardableResult
    static func openWindow() -> Bool {
        guard FileManager.default.fileExists(atPath: window.path) else { return false }
        NSWorkspace.shared.openApplication(
            at: window, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    /// What the row in the sidebar shows.
    static var icon: NSImage {
        FileManager.default.fileExists(atPath: window.path)
            ? NSWorkspace.shared.icon(forFile: window.path)
            : NSImage(
                systemSymbolName: "dot.radiowaves.left.and.right",
                accessibilityDescription: "AirDrop") ?? NSImage()
    }
}
