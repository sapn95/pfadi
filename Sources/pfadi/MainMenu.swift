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
        main.addItem(fileMenu())
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
            withTitle: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        let redo = menu.addItem(
            withTitle: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
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

    private static func fileMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")

        let folder = menu.addItem(
            withTitle: "New Folder",
            action: #selector(BrowserViewController.newFolder(_:)),
            keyEquivalent: "n"
        )
        folder.keyEquivalentModifierMask = [.command, .shift]

        // F2 rather than return, which this application already spends on
        // opening things. Windows has taught most people F2 anyway.
        let rename = menu.addItem(
            withTitle: "Rename",
            action: #selector(BrowserViewController.renameSelection(_:)),
            keyEquivalent: String(utf16CodeUnits: [unichar(NSF2FunctionKey)], count: 1)
        )
        rename.keyEquivalentModifierMask = []

        menu.addItem(.separator())

        let trash = menu.addItem(
            withTitle: "Move to Trash",
            action: #selector(BrowserViewController.moveToTrash(_:)),
            keyEquivalent: String(utf16CodeUnits: [unichar(NSBackspaceCharacter)], count: 1)
        )
        trash.keyEquivalentModifierMask = [.command]

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

        let favourite = menu.addItem(
            withTitle: "Add to Favourites",
            action: #selector(BrowserViewController.toggleFavourite(_:)),
            keyEquivalent: "d"
        )
        favourite.keyEquivalentModifierMask = [.command]

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
