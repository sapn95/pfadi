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
        Self.applyAppearance(Preferences().appearance)

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

    /// ⌃⌘A, and the View menu.
    @objc func cycleAppearance(_ sender: Any?) {
        let preferences = Preferences()
        let all = Appearance.allCases
        let next = all[(all.firstIndex(of: preferences.appearance).map { $0 + 1 } ?? 0) % all.count]
        preferences.appearance = next
        Self.applyAppearance(next)
        BrowserWindow.frontmost?.browser.announceAppearance(next)
    }

    /// Puts the whole application into one appearance.
    ///
    /// On `NSApp` rather than per window, so panels, menus, the Open With
    /// dialog and every window opened later agree with each other. Setting it
    /// per window leaves the ones you have not opened yet in whatever the
    /// system felt like.
    static func applyAppearance(_ appearance: Appearance) {
        NSApp.appearance = appearance.appearanceName.map { NSAppearance(named: .init($0)) } ?? nil
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

    /// Says so when the copy running is older than the copy installed.
    ///
    /// Checked when the application comes forward rather than at launch: a
    /// `brew upgrade` happens while this is sitting in the background, and at
    /// launch there was nothing to say.
    func applicationDidBecomeActive(_ notification: Notification) {
        Self.keepDockTile()
        guard let message = Self.upgradeNotice() else { return }
        // Once per version, not once per switch to the window. Somebody who
        // has read it and carried on working does not need it every time they
        // click back.
        guard message != lastUpgradeNotice else { return }
        lastUpgradeNotice = message
        BrowserWindow.frontmost?.browser.announceUpgrade(message)
    }

    private var lastUpgradeNotice: String?

    /// Points a pfadi tile in the Dock at whatever is running.
    ///
    /// Homebrew installs into a path with the version in it, so every upgrade
    /// left the tile pointing at a folder that had just been deleted and it had
    /// to be dragged in again. Aiming it at the stable `opt` symlink does not
    /// help: the Dock rewrites the entry to the resolved path the moment the
    /// application runs, which is measured in `DockTile`.
    ///
    /// So it is repaired instead, from the one place that knows where the
    /// running bundle is. Only repaired: an application that adds itself to
    /// somebody's Dock because it was started is doing something it was not
    /// asked to.
    private static func keepDockTile() {
        // What the system would launch now, not what is running. Those differ
        // in exactly the case this exists for: after `brew upgrade` the running
        // bundle is still the old versioned path, which is also what the tile
        // says, so repairing towards `Bundle.main` would find nothing to do and
        // leave the question mark for later.
        //
        // The bundle has to be there: LaunchServices answers from a database
        // that can name something already deleted, and a tile pointed at that
        // is the bug rather than the fix.
        guard let identifier = Bundle.main.bundleIdentifier,
            let installed = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: identifier),
            FileManager.default.fileExists(atPath: installed.path)
        else { return }
        // A real bundle, not a build directory. `swift run pfadi` and the
        // checks have no `.app` around them, and pointing somebody's Dock tile
        // at `.build/debug` would be a far worse bug than the one this fixes.
        guard DockTile.isPfadi(DockTile.urlString(for: installed)) else { return }
        DockTile.point(at: installed, repairingOnly: true)
    }

    /// What the system would launch now, against what is running.
    static func upgradeNotice() -> String? {
        let running = Bundle.main
        guard let version = running.infoDictionary?["CFBundleShortVersionString"] as? String,
            let identifier = running.bundleIdentifier,
            let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
            let theirs = Bundle(url: installed)?
                .infoDictionary?["CFBundleShortVersionString"] as? String
        else { return nil }

        return InstalledVersion.message(
            running: version,
            runningPath: running.bundleURL.standardizedFileURL.path,
            installed: theirs,
            installedPath: installed.standardizedFileURL.path)
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
