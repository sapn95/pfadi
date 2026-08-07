import AppKit
import PfadiCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// What was asked for before any window existed.
    ///
    /// LaunchServices delivers the open event *before*
    /// `applicationDidFinishLaunching`, with no windows yet in existence, so
    /// this is the path a cold `pfadi ~/git` actually takes. It is held here
    /// and the first of them seeds the window, rather than a window being made
    /// for the remembered folder and the request arriving beside it as a tab.
    private var pending: [PathCompletion.Target] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()

        let queued = pending
        pending = []

        let first = BrowserWindow(directory: Self.startDirectory(explicit: queued.first))
        first.show()
        // The first target seeded the window, so it is shown there rather than
        // in a tab of its own; the rest arrive as tabs.
        if let asked = queued.first { first.show(asked) }
        for target in queued.dropFirst() { first.openTab(showing: target) }

        NSApp.activate(ignoringOtherApps: true)
    }

    /// `open -a Pfadi <path>`, a drop on the Dock icon, and `pfadi://reveal`.
    ///
    /// A second invocation opens a tab rather than replacing what is on screen:
    /// being sent somewhere new should not lose the folder you were in.
    func application(_ application: NSApplication, open urls: [URL]) {
        let targets = urls.compactMap(Self.target(for:))
        guard !targets.isEmpty else { return }

        guard let front = BrowserWindow.frontmost else {
            // Nothing exists yet, so these are held until there is a window.
            pending += targets
            return
        }

        // Every URL, not only the first: `open -a Pfadi a b c` asked for three
        // folders and silently dropping two of them is not an answer.
        for target in targets {
            front.openTab(showing: target)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Paths given on the command line, before the application starts.
    func openOnLaunch(_ targets: [PathCompletion.Target]) {
        pending += targets
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
        front.openTab(showing: .directory(front.browser.currentDirectory))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// What an incoming URL means.
    ///
    /// `pfadi://reveal?path=…` says "select this" and is believed, because
    /// only this application sends it. A file URL is read off the disk: a
    /// folder is opened, anything else is shown in the folder holding it,
    /// which is the only sensible reading of "open this" for a file.
    static func target(for url: URL) -> PathCompletion.Target? {
        if let asked = PfadiURL.target(of: url) { return asked }
        guard url.isFileURL else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        else { return nil }
        return isDirectory.boolValue
            ? .directory(PathCompletion.directoryURL(url))
            : .file(url.standardizedFileURL)
    }

    /// The folder a target wants to be looking at.
    static func folder(of target: PathCompletion.Target) -> URL {
        switch target {
        case .directory(let url): return url
        case .file(let url): return PathCompletion.directoryURL(url.deletingLastPathComponent())
        }
    }

    private static func startDirectory(explicit: PathCompletion.Target?) -> URL {
        StartDirectory.choose(
            explicit: explicit.map(folder(of:)),
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            remembered: Preferences().lastDirectory,
            home: FileManager.default.homeDirectoryForCurrentUser
        )
    }
}
