import AppKit

/// The menu bar, built in code so the project stays free of nib files.
///
/// Every item targets `nil`, which sends it down the responder chain to
/// whichever view controller is in front. That is also what enables and
/// disables the items for free.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(appMenu())
        main.addItem(goMenu())
        main.addItem(viewMenu())
        main.addItem(actionsMenu())
        return main
    }

    private static func appMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "pfadi")
        menu.addItem(
            withTitle: "About pfadi",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Hide pfadi",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        menu.addItem(
            withTitle: "Quit pfadi",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.submenu = menu
        return item
    }

    private static func goMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Go")

        let focus = menu.addItem(
            withTitle: "Go to Path",
            action: #selector(BrowserViewController.focusPathField(_:)),
            keyEquivalent: "g"
        )
        focus.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(.separator())

        let up = menu.addItem(
            withTitle: "Enclosing Folder",
            action: #selector(BrowserViewController.goToParent(_:)),
            keyEquivalent: String(utf16CodeUnits: [unichar(NSUpArrowFunctionKey)], count: 1)
        )
        up.keyEquivalentModifierMask = [.command]

        let home = menu.addItem(
            withTitle: "Home",
            action: #selector(BrowserViewController.goHome(_:)),
            keyEquivalent: "h"
        )
        home.keyEquivalentModifierMask = [.command, .shift]

        item.submenu = menu
        return item
    }

    private static func viewMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")

        let hidden = menu.addItem(
            withTitle: "Show Hidden Files",
            action: #selector(BrowserViewController.toggleHidden(_:)),
            keyEquivalent: "."
        )
        hidden.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(
            withTitle: "Refresh",
            action: #selector(BrowserViewController.refresh(_:)),
            keyEquivalent: "r"
        )

        item.submenu = menu
        return item
    }

    private static func actionsMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Actions")

        let copy = menu.addItem(
            withTitle: "Copy Path",
            action: #selector(BrowserViewController.copyPath(_:)),
            keyEquivalent: "c"
        )
        copy.keyEquivalentModifierMask = [.command, .shift]

        let terminal = menu.addItem(
            withTitle: "Open Terminal Here",
            action: #selector(BrowserViewController.openTerminalHere(_:)),
            keyEquivalent: "t"
        )
        terminal.keyEquivalentModifierMask = [.command, .control]

        let reveal = menu.addItem(
            withTitle: "Reveal in Finder",
            action: #selector(BrowserViewController.revealInFinder(_:)),
            keyEquivalent: "r"
        )
        reveal.keyEquivalentModifierMask = [.command, .shift]

        item.submenu = menu
        return item
    }
}
