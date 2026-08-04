import AppKit
import PfadiCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var browser: BrowserViewController?

    /// A folder handed over before the window existed. `open -a Pfadi ~/git`
    /// can deliver its URL either side of applicationDidFinishLaunching, so
    /// both orders have to work.
    private var pending: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()

        let preferences = Preferences()
        let favourites = Favourites(preferences: preferences)

        let browser = BrowserViewController(
            directory: Self.startDirectory(explicit: pending),
            preferences: preferences,
            favourites: favourites
        )
        pending = nil
        self.browser = browser

        let sidebar = SidebarViewController(favourites: favourites)
        sidebar.onSelect = { [weak browser] url in browser?.navigate(to: url) }
        browser.onFavouritesChanged = { [weak sidebar] in sidebar?.reload() }

        // A split view controller rather than a hand-rolled NSSplitView: it is
        // what gives the sidebar its translucency, its collapse behaviour and
        // the ⌃⌘S menu item, none of which are worth reimplementing.
        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 320
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: browser))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = split
        window.titlebarAppearsTransparent = true
        window.title = "pfadi"
        window.setFrameAutosaveName("io.github.sapn95.pfadi.main")
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }

    /// `open -a Pfadi <path>`, and dropping a folder on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        show(Self.folder(for: url))
    }

    /// A path given on the command line, before the application starts.
    func openOnLaunch(_ url: URL) {
        pending = Self.folder(for: url)
    }

    private func show(_ directory: URL) {
        guard let browser else {
            pending = directory
            return
        }
        browser.navigate(to: directory)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A file is shown in the folder that holds it, which is the only sensible
    /// reading of "open this" for something that is not a directory.
    private static func folder(for url: URL) -> URL {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue ? url : url.deletingLastPathComponent()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
