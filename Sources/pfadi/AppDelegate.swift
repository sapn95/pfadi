import AppKit
import PfadiCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A folder handed over before any window existed. `open -a Pfadi ~/git`
    /// can deliver its URL either side of applicationDidFinishLaunching, so
    /// both orders have to work.
    private var pending: URL?
    /// Further folders asked for before any window existed.
    private var queued: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()

        let first = BrowserWindow(directory: Self.startDirectory(explicit: pending))
        pending = nil
        first.show()
        for url in queued { first.openTab(at: url) }
        queued = []

        NSApp.activate(ignoringOtherApps: true)
    }

    /// `open -a Pfadi <path>`, and dropping a folder on the Dock icon.
    ///
    /// A second invocation opens a tab rather than replacing what is on screen:
    /// being sent somewhere new should not lose the folder you were in.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }

        guard let front = BrowserWindow.frontmost else {
            // Nothing exists yet, so the first one seeds the window and the
            // rest arrive as tabs once it does.
            pending = Self.folder(for: urls[0])
            for url in urls.dropFirst() { queued.append(Self.folder(for: url)) }
            return
        }
        // Every URL, not only the first: `open -a Pfadi a b c` asked for three
        // folders and silently dropping two of them is not an answer.
        for url in urls {
            front.openTab(at: Self.folder(for: url))
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A path given on the command line, before the application starts.
    func openOnLaunch(_ url: URL) {
        pending = Self.folder(for: url)
    }

    @objc func newWindow(_ sender: Any?) {
        let directory =
            BrowserWindow.frontmost?.browser.currentDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
        BrowserWindow(directory: directory).show()
    }

    @objc func newTab(_ sender: Any?) {
        guard let front = BrowserWindow.frontmost else {
            newWindow(sender)
            return
        }
        front.openTab(at: front.browser.currentDirectory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// A file is shown in the folder that holds it, which is the only sensible
    /// reading of "open this" for something that is not a directory.
    private static func folder(for url: URL) -> URL {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue ? url : url.deletingLastPathComponent()
    }

    private static func startDirectory(explicit: URL?) -> URL {
        StartDirectory.choose(
            explicit: explicit,
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            remembered: Preferences().lastDirectory,
            home: FileManager.default.homeDirectoryForCurrentUser
        )
    }
}
