import AppKit
import PfadiCore

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
        main.addItem(editMenu())
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

        menu.addItem(
            withTitle: "New Tab",
            action: #selector(AppDelegate.newTab(_:)),
            keyEquivalent: "t"
        )
        let window = menu.addItem(
            withTitle: "New Window",
            action: #selector(AppDelegate.newWindow(_:)),
            keyEquivalent: "n"
        )
        window.keyEquivalentModifierMask = [.command]

        let openTab = menu.addItem(
            withTitle: "Open in New Tab",
            action: #selector(BrowserViewController.openInNewTab(_:)),
            keyEquivalent: String(utf16CodeUnits: [unichar(NSDownArrowFunctionKey)], count: 1)
        )
        openTab.keyEquivalentModifierMask = [.command]

        menu.addItem(.separator())

        let file = menu.addItem(
            withTitle: "New File",
            action: #selector(BrowserViewController.newFile(_:)),
            keyEquivalent: "n"
        )
        file.keyEquivalentModifierMask = [.command, .control]

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

        let info = menu.addItem(
            withTitle: "Get Info",
            action: #selector(BrowserViewController.showInfo(_:)),
            keyEquivalent: "i"
        )
        info.keyEquivalentModifierMask = [.command]

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

    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")

        menu.addItem(
            withTitle: "Copy",
            action: #selector(BrowserViewController.copy(_:)),
            keyEquivalent: "c"
        )
        menu.addItem(
            withTitle: "Paste",
            action: #selector(BrowserViewController.paste(_:)),
            keyEquivalent: "v"
        )

        // Finder's spelling: there is no cut for files, there is copy and then
        // "move it here instead", and the modifier is the one people know.
        let move = menu.addItem(
            withTitle: "Move Item Here",
            action: #selector(BrowserViewController.pasteAsMove(_:)),
            keyEquivalent: "v"
        )
        move.keyEquivalentModifierMask = [.command, .option]

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

        let back = menu.addItem(
            withTitle: "Back",
            action: #selector(BrowserViewController.goBack(_:)),
            keyEquivalent: "["
        )
        back.keyEquivalentModifierMask = [.command]

        let forward = menu.addItem(
            withTitle: "Forward",
            action: #selector(BrowserViewController.goForward(_:)),
            keyEquivalent: "]"
        )
        forward.keyEquivalentModifierMask = [.command]

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

        let created = menu.addItem(
            withTitle: "Show Created Column",
            action: #selector(BrowserViewController.toggleCreatedColumn(_:)),
            keyEquivalent: "k"
        )
        created.keyEquivalentModifierMask = [.command, .shift]

        let appearance = menu.addItem(
            withTitle: "Appearance",
            action: #selector(AppDelegate.cycleAppearance(_:)),
            keyEquivalent: "a"
        )
        appearance.keyEquivalentModifierMask = [.command, .control]

        // The same list the headers offer behind a right-click, put where it
        // can be found by somebody who does not know to right-click a header.
        let columns = menu.addItem(withTitle: "Columns", action: nil, keyEquivalent: "")
        columns.submenu = NSMenu(title: "Columns")
        columns.submenu?.delegate = ColumnsMenuDelegate.shared

        menu.addItem(.separator())

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
            withTitle: "Show in Finder",
            action: #selector(BrowserViewController.showInFinder(_:)),
            keyEquivalent: "r"
        )
        reveal.keyEquivalentModifierMask = [.command, .shift]

        item.submenu = menu
        return item
    }
}

/// Fills the View menu's Columns submenu when it opens.
///
/// Built on demand rather than at launch, and from the window in front rather
/// than from a stored list, so it says what is true of the list somebody is
/// actually looking at. A menu built once at launch stops being true the first
/// time a column is switched.
final class ColumnsMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = ColumnsMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let showing = Set(BrowserWindow.frontmost?.browser.visibleColumns ?? [])

        for column in ListingColumn.allCases {
            let item = menu.addItem(
                withTitle: column.title,
                action: #selector(BrowserViewController.toggleColumn(_:)),
                keyEquivalent: "")
            item.representedObject = column.rawValue
            item.state = showing.contains(column.rawValue) ? .on : .off
            // Name is shown ticked and inert rather than offered and refused.
            item.isEnabled = column.canBeHidden
        }
        menu.addItem(.separator())
        let hint = menu.addItem(
            withTitle: "Drag a header to reorder", action: nil, keyEquivalent: "")
        hint.isEnabled = false
    }
}
