import AppKit
import PfadiCore

/// One window, or one tab: on this system those are the same thing.
///
/// macOS does window tabbing itself, so a tab is a window that has been asked
/// to join another one. Adopting that rather than drawing a tab bar by hand
/// brings ⌘⇧[ and ⌘⇧], Merge All Windows, Move Tab to New Window and the rest
/// of the Window menu along with it, all behaving the way they do everywhere
/// else.
final class BrowserWindow {
    let window: NSWindow
    let browser: BrowserViewController

    private let sidebar: SidebarViewController
    private let toolbar = NavigationToolbar()

    /// Everything currently open, so the delegate can find the front one.
    private(set) static var all: [BrowserWindow] = []

    init(directory: URL, preferences: Preferences = Preferences()) {
        let favourites = Favourites(preferences: preferences)

        browser = BrowserViewController(
            directory: directory, preferences: preferences, favourites: favourites)
        sidebar = SidebarViewController(favourites: favourites)

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 320
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: browser))

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = split
        window.toolbar = toolbar.makeToolbar()
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.title = directory.lastPathComponent
        // A shared identifier is what lets two of these become tabs of each
        // other. Without it every ⌘T is a separate window.
        window.tabbingIdentifier = "io.github.sapn95.pfadi.browser"
        window.tabbingMode = .preferred
        window.isReleasedWhenClosed = false

        wire()
        Self.all.append(self)
    }

    private func wire() {
        sidebar.onSelect = { [weak browser] url in browser?.navigate(to: url) }
        browser.onFavouritesChanged = { [weak sidebar] in sidebar?.reload() }
        browser.onNewTab = { [weak self] url in self?.openTab(at: url) }
        toolbar.onBack = { [weak browser] in browser?.goBack(nil) }
        toolbar.onForward = { [weak browser] in browser?.goForward(nil) }
        browser.onHistoryChanged = { [weak self] back, forward in
            self?.toolbar.update(canGoBack: back, canGoForward: forward)
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Self.all.removeAll { $0 === self }
        }
    }

    func show() {
        // Only the first window restores a saved frame. Giving every tab the
        // same autosave name makes them fight over it and land on top of each
        // other when they are torn off again.
        if Self.all.count == 1 {
            window.setFrameAutosaveName("io.github.sapn95.pfadi.main")
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// A new tab on this window, showing `url`.
    @discardableResult
    func openTab(at url: URL) -> BrowserWindow {
        let tab = BrowserWindow(directory: url)
        window.addTabbedWindow(tab.window, ordered: .above)
        tab.window.makeKeyAndOrderFront(nil)
        return tab
    }

    static var frontmost: BrowserWindow? {
        if let key = NSApp.keyWindow, let found = all.first(where: { $0.window === key }) {
            return found
        }
        return all.last
    }
}
