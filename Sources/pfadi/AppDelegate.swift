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

        let browser = BrowserViewController(directory: pending ?? Self.startDirectory())
        pending = nil
        self.browser = browser

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = browser
        window.titlebarAppearsTransparent = true
        window.title = "pfadi"
        window.setFrameAutosaveName("io.github.sapn95.pfadi.main")
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }

    /// `open -a Pfadi <path>`, and dropping a folder on the Dock icon.
    /// A file is shown in the folder that holds it, which is the only sensible
    /// reading of "open this" for something that is not a directory.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let target = isDirectory.boolValue ? url : url.deletingLastPathComponent()

        if let browser {
            browser.navigate(to: target)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            pending = target
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Opening in the shell's working directory is what makes `open .` useful.
    /// A launched .app inherits `/`, so home is the honest fallback.
    private static func startDirectory() -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return cwd.path == "/"
            ? FileManager.default.homeDirectoryForCurrentUser
            : PathCompletion.directoryURL(cwd)
    }
}
