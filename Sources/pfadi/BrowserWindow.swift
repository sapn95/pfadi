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

    let sidebar: SidebarViewController
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
        // A browser has no business being sixty points tall. Without a floor
        // the window can be dragged, or laid out, down to nothing, and the
        // frame autosave then restores that nothing on every launch after.
        window.contentMinSize = NSSize(width: 520, height: 320)
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
        observeActivation()
        Self.all.append(self)
    }

    private func wire() {
        sidebar.onSelect = { [weak browser] url in browser?.navigate(to: url) }
        sidebar.onConnect = { [weak browser] url in
            guard let url else {
                browser?.connectToServer(nil)
                return
            }
            browser?.connect(to: url)
        }
        browser.onFavouritesChanged = { [weak sidebar] in sidebar?.reload() }
        sidebar.onDrop = { [weak browser] sources, destination in
            browser?.transfer(sources, into: destination)
        }
        browser.onNewTab = { [weak self] url in self?.openTab(at: url) }
        toolbar.onBack = { [weak browser] in browser?.goBack(nil) }
        toolbar.onForward = { [weak browser] in browser?.goForward(nil) }
        browser.onHistoryChanged = { [weak self] back, forward in
            self?.toolbar.update(canGoBack: back, canGoForward: forward)
        }

        // The token is kept and removed when it fires: a block observer that
        // is never removed keeps its closure, and with it the window, alive
        // for the life of the process. Held in a box rather than a captured
        // var, which the closure would be reading while it is still being
        // assigned.
        let token = ObserverToken()
        token.value = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            if let observer = token.value {
                NotificationCenter.default.removeObserver(observer)
            }
            guard let self else { return }
            Self.all.removeAll { $0 === self }
        }
    }

    /// Volumes and cloud accounts are looked for again when the window comes
    /// forward, which is when something is likely to have been mounted or
    /// signed out of, rather than on every navigation.
    private func observeActivation() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.sidebar.reload(rediscover: true)
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
        openTab(showing: .directory(url))
    }

    /// A new tab showing a folder, or a folder with one of its files selected.
    @discardableResult
    func openTab(showing target: PathCompletion.Target) -> BrowserWindow {
        let tab = BrowserWindow(directory: AppDelegate.folder(of: target))
        window.addTabbedWindow(tab.window, ordered: .above)
        tab.window.makeKeyAndOrderFront(nil)
        tab.show(target)
        return tab
    }

    /// Finishes off a window that was just made at the right folder.
    ///
    /// A folder needs nothing more; a file still has to be selected.
    func show(_ target: PathCompletion.Target) {
        if case .file(let url) = target {
            browser.reveal(url)
        }
    }

    /// Takes a window that is somewhere else to a target.
    func go(to target: PathCompletion.Target) {
        switch target {
        case .directory(let url): browser.navigate(to: url)
        case .file(let url): browser.reveal(url)
        }
    }

    /// For the checks: selects the sidebar row for a folder.
    @discardableResult
    func clickSidebarRow(_ url: URL) -> Bool {
        sidebar.clickRow(at: url)
    }

    static var frontmost: BrowserWindow? {
        if let key = NSApp.keyWindow, let found = all.first(where: { $0.window === key }) {
            return found
        }
        return all.last
    }
}

/// Somewhere to put an observer token that the observer's own closure can read.
private final class ObserverToken: @unchecked Sendable {
    var value: (any NSObjectProtocol)?
}
