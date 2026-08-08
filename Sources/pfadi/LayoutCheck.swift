import AppKit
import PfadiCore

/// `pfadi --layout-check`: builds the real window off-screen at several sizes,
/// forces a layout pass, and says whether anything ended up somewhere useless.
///
/// This exists because a layout mistake is invisible to everything else. The
/// build is green, the tests pass, the application launches, and the window is
/// sixty points tall with the filter pushed off the edge. Nobody finds that
/// except by looking, and looking is exactly what an automated check cannot do
/// — but it can measure, and every one of those failures was a number being
/// wrong.
enum LayoutCheck {
    private static var failures = 0

    static func run() -> Never {
        // A real window, because a view laid out on its own does not have to
        // agree with what a window will do to it.
        for size in [NSSize(width: 520, height: 320), NSSize(width: 1058, height: 560)] {
            check(at: size)
        }

        appearance()
        behaviour()
        print(failures == 0 ? "\nall checks ok" : "\n\(failures) problems")
        exit(failures == 0 ? 0 : 1)
    }

    /// Dark, and dark by default.
    ///
    /// Checked on NSApp rather than on a window: a window can be told to be
    /// dark while every panel and menu around it stays light, which is the
    /// half-done version of this that looks worse than not doing it.
    private static func appearance() {
        print("\nappearance")

        expect(
            Preferences(store: MemoryDefaults()).appearance == .dark,
            "dark for somebody who has never touched it")

        for wanted in Appearance.allCases {
            AppDelegate.applyAppearance(wanted)
            switch wanted {
            case .system:
                expect(NSApp.appearance == nil, "Match System hands the choice back")
            case .dark, .light:
                expect(
                    NSApp.appearance?.name.rawValue == wanted.appearanceName,
                    "\(wanted.title) is applied to the whole application, got "
                        + (NSApp.appearance?.name.rawValue ?? "nothing"))
            }

            // Asked here, while this run set it, rather than after restoring
            // whatever this machine has saved: a check that reads somebody's
            // preference and then asserts a value has stopped checking the
            // code and started checking the machine.
            if wanted == .dark {
                expect(
                    NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                    "and dark really takes effect, got "
                        + NSApp.effectiveAppearance.name.rawValue)
            }
        }

        // Left on dark for the checks below, so the windows they build are the
        // ones somebody who has changed nothing would see.
        AppDelegate.applyAppearance(.dark)
    }

    /// A defaults store that touches nothing, so asking what the default is
    /// cannot be answered by whatever this machine happens to have saved.
    private final class MemoryDefaults: KeyValueStore {
        func object(forKey key: String) -> Any? { nil }
        func set(_ value: Any?, forKey key: String) {}
    }

    private static func check(at size: NSSize) {
        print("\n\(Int(size.width))x\(Int(size.height))")

        let window = BrowserWindow(
            directory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library"))
        window.window.setContentSize(size)
        window.window.layoutIfNeeded()

        let drawn = window.sidebar.drawnRows()
        print("  sidebar: \(drawn.joined(separator: ", "))")
        expect(drawn.contains("Computer"), "the root is in the sidebar")

        let components = window.browser.pathComponents()
        expect(
            components.contains("/"),
            "the path starts at the root, got \(components.joined(separator: " "))")

        let report = window.browser.layoutReport()
        let bounds = report.bounds

        expect(bounds.width >= 300, "the browser is at least 300 wide, got \(Int(bounds.width))")
        expect(bounds.height >= 200, "and at least 200 tall, got \(Int(bounds.height))")

        for (name, frame) in report.frames {
            expect(frame.width > 0 && frame.height > 0, "\(name) has a size")
            // Half a control hanging off the edge is the shape every one of
            // these failures took: present, laid out, and unreachable.
            expect(frame.minX >= -0.5, "\(name) starts inside the view")
            expect(
                frame.maxX <= bounds.width + 0.5,
                "\(name) ends inside the view, \(Int(frame.maxX)) of \(Int(bounds.width))")
            expect(frame.maxY <= bounds.height + 0.5, "\(name) fits vertically")
        }

        if let path = report.frames["path row"], let filter = report.frames["filter"] {
            expect(path.maxX <= filter.minX + 0.5, "the path row stops before the filter")
            expect(filter.width >= 80, "the filter is wide enough to type in")
        }
        if let list = report.frames["list"] {
            expect(list.height >= 150, "the list has room, got \(Int(list.height))")
        }
        expect(
            window.window.contentMinSize.height >= 300,
            "the window cannot be shrunk to a strip")

        // Ambiguity is how the arrow ended up at the far right of the row: it
        // had an upper bound and nothing saying where it actually went, so
        // AppKit picked. A layout that has a choice is a layout that will
        // eventually make the wrong one.
        let ambiguous = ambiguousViews(in: window.window.contentView)
        expect(
            ambiguous.isEmpty,
            ambiguous.isEmpty
                ? "nothing is free to move about"
                : "these have no fixed position: \(ambiguous.joined(separator: ", "))")
    }

    /// What happens when somebody clicks, rather than what is on screen.
    ///
    /// The model was right the whole time the root was unreachable, so reading
    /// the model proved nothing. These go through the same code a click does.
    private static func behaviour() {
        print("\nbehaviour")

        // A folder this check made, rather than whatever happens to be in the
        // home directory of whoever is running it. On another machine, and on
        // a CI runner in particular, the real one holds something else
        // entirely and the counts below would mean nothing.
        guard let start = makeFixture() else {
            failures += 1
            print("  FAIL could not make a folder to check against")
            return
        }
        defer { try? FileManager.default.removeItem(at: start) }

        let window = BrowserWindow(directory: start)
        window.window.setContentSize(NSSize(width: 1058, height: 560))
        window.window.layoutIfNeeded()

        expect(
            window.browser.currentDirectory.path == start.path,
            "it opens where it was told, got \(window.browser.currentDirectory.path)")

        // The one that was broken twice: the leftmost folder in the path.
        settle(until: { window.browser.listedDirectory?.path == start.path })
        expect(window.browser.clickPathComponent("/"), "the root is there to click")
        expect(
            window.browser.currentDirectory.path == "/",
            "clicking it goes to /, got \(window.browser.currentDirectory.path)")

        // And back down again, so this is not passing because everything
        // happens to be "/".
        let home = FileManager.default.homeDirectoryForCurrentUser
        expect(window.clickSidebarRow(home), "Home is in the sidebar and can be clicked")
        settle(seconds: 0.3)
        expect(
            window.browser.currentDirectory.path
                == FileManager.default
                .homeDirectoryForCurrentUser.path,
            "clicking Home goes home, got \(window.browser.currentDirectory.path)")

        // The rest of the window, exercised the same way: through the code a
        // key or a click runs, not around it.
        let browser = window.browser
        browser.navigate(to: start)
        // For this folder's rows, not merely for some. Waiting on "any rows"
        // is satisfied by the ones already there from the folder just left.
        settle(until: { browser.listedDirectory?.path == start.path })
        let all = browser.rowCount
        expect(all == 4, "the folder lists what was put in it, got \(all) of 4")
        expect(
            browser.showsHiddenFiles,
            "dotfiles are shown unless somebody said otherwise")

        browser.setFilter("report")
        settle(seconds: 0.2)
        expect(
            browser.rowCount == 2,
            "the filter finds both reports and nothing else, got \(browser.rowCount)")
        browser.setFilter("")
        settle(seconds: 0.2)
        expect(browser.rowCount == all, "and clearing it puts everything back")

        let above = start.deletingLastPathComponent()
        browser.goToParent(nil)
        settle(until: { browser.listedDirectory?.path == above.path })
        expect(
            browser.currentDirectory.path == above.path,
            "the enclosing folder is up one, got \(browser.currentDirectory.path)")
        browser.goBack(nil)
        expect(
            browser.currentDirectory.path == start.path,
            "back returns to where it was, got \(browser.currentDirectory.path)")
        browser.goForward(nil)
        expect(
            browser.currentDirectory.path == above.path,
            "and forward goes on again, got \(browser.currentDirectory.path)")

        browser.navigate(to: start)
        settle(until: { browser.listedDirectory?.path == start.path })
        let wasFavourite = browser.isFavourite
        browser.toggleFavourite(nil)
        expect(browser.isFavourite != wasFavourite, "⌘D changes whether it is a favourite")
        browser.toggleFavourite(nil)
        expect(browser.isFavourite == wasFavourite, "and ⌘D again puts it back")

        revealing(in: window, fixture: start)
        sizing(in: window, fixture: start)
        selecting(in: window, fixture: start)
    }

    /// More than one row at a time.
    ///
    /// The table refused to hold a second selected row at all, so every action
    /// below was written against one file and quietly stayed that way. These go
    /// through the table's own selection, which is the thing that was wrong.
    private static func selecting(in window: BrowserWindow, fixture: URL) {
        let browser = window.browser
        browser.navigate(to: fixture)
        settle(until: { browser.listedDirectory?.path == fixture.path })

        let all = browser.rowCount
        guard all >= 3 else {
            failures += 1
            print("  FAIL the fixture has enough rows to select several, got \(all)")
            return
        }

        // ⇧↓ from the top: a run of rows.
        browser.selectRange(0..<3)
        expect(
            browser.selectedNames.count == 3,
            "⇧↓ holds three rows, got \(browser.selectedNames.count)")

        // ⌘-click one more, which is the other half of what was missing.
        browser.selectRange(0..<1)
        browser.addToSelection(row: 2)
        expect(
            browser.selectedNames.count == 2,
            "⌘-click adds a row without losing the first, got \(browser.selectedNames.count)")

        browser.selectRange(0..<3)
        expect(
            browser.statusLine.contains("3 of"),
            "the status line counts them, got \(browser.statusLine)")

        // The clipboard, because a selection that cannot be copied is a
        // selection that does nothing.
        browser.copy(nil)
        let copied =
            NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        expect(copied.count == 3, "⌘C copies all three, got \(copied.count)")

        // And it survives a reload, which is what the watcher does whenever
        // anything in the folder is written.
        browser.refresh(nil)
        settle(until: { browser.selectedNames.count == 3 })
        expect(
            browser.selectedNames.count == 3,
            "a reload keeps them selected, got \(browser.selectedNames.count)")

        dropping(in: window, fixture: fixture)
        sorting(in: window, fixture: fixture)
        showingInFinder(in: window, fixture: fixture)
        openingFolders(in: window, fixture: fixture)
        creating(in: window, fixture: fixture)
        sidebarFilter(in: window)
        icons(in: window, fixture: fixture)
    }

    /// A file shows the icon of whatever opens it.
    private static func icons(in window: BrowserWindow, fixture: URL) {
        let manager = FileManager.default
        let folder = fixture.appendingPathComponent("iconable")
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["page.html", "note.txt"] {
            manager.createFile(
                atPath: folder.appendingPathComponent(name).path, contents: Data("x".utf8))
        }

        let html = folder.appendingPathComponent("page.html")
        let text = folder.appendingPathComponent("note.txt")

        // Against the same resolution the icon uses. The first version of this
        // asked LaunchServices itself, which is a different question — it
        // passed here and failed on a runner where the two disagreed about
        // .txt.
        for file in [html, text] {
            guard let application = FileIcons.openingApplication(for: file) else {
                print("  ..   nothing opens \(file.lastPathComponent) here, skipped")
                continue
            }

            expect(
                sameImage(
                    FileIcons.icon(for: file, isDirectory: false),
                    NSWorkspace.shared.icon(forFile: application.path)),
                "\(file.lastPathComponent) shows \(application.lastPathComponent), which opens it")

            // The substantive claim, and the one that does not depend on which
            // application happens to be installed: it is not the document icon
            // any more.
            expect(
                !sameImage(
                    FileIcons.icon(for: file, isDirectory: false),
                    NSWorkspace.shared.icon(forFile: file.path)),
                "and not the document icon it used to show")
        }

        // And a folder keeps its own, because no application opens a folder
        // and the folder icon carries its colour and its emoji.
        expect(
            sameImage(
                FileIcons.icon(for: folder, isDirectory: true),
                NSWorkspace.shared.icon(forFile: folder.path)),
            "and a folder keeps the one macOS gives it")

        try? manager.removeItem(at: folder)
    }

    /// The sidebar's filter, and that it is the same match as everywhere else.
    private static func sidebarFilter(in window: BrowserWindow) {
        let sidebar = window.sidebar
        let all = sidebar.drawnRows()
        expect(all.contains("Downloads"), "Downloads is in the sidebar to begin with")

        // Letters from the middle, not a prefix and not a run: this is the
        // whole reason the filter is fuzzy rather than `contains`, and thirty
        // favourites is when it matters.
        sidebar.filter(by: "dwn")
        let narrowed = sidebar.drawnRows()
        expect(
            narrowed.contains("Downloads"),
            "dwn finds Downloads, got \(narrowed.joined(separator: ", "))")
        expect(
            narrowed.count < all.count,
            "and leaves out the rest, \(all.count) rows became \(narrowed.count)")
        expect(
            narrowed.contains("(connect)"),
            "Connect to Server stays reachable whatever was typed")

        sidebar.filter(by: "zzzznothing")
        expect(
            sidebar.drawnRows().contains("[No match]"),
            "nothing matching says so, got \(sidebar.drawnRows().joined(separator: ", "))")

        sidebar.filter(by: "")
        expect(
            sidebar.drawnRows() == all,
            "and clearing it puts everything back, \(sidebar.drawnRows().count) of \(all.count)")
    }

    /// Making a folder and making a file, from the menu people reach for.
    private static func creating(in window: BrowserWindow, fixture: URL) {
        let browser = window.browser
        let made = fixture.appendingPathComponent("made-here")
        try? FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)

        browser.navigate(to: made)
        settle(until: { browser.listedDirectory?.path == made.path })
        expect(browser.rowCount == 0, "an empty folder to make things in")

        expect(browser.clickContextMenuItem("New Folder"), "New Folder is in the right-click menu")
        settle(until: { browser.rowIndex(of: "untitled folder") != nil }, seconds: 5)
        expect(
            browser.rowIndex(of: "untitled folder") != nil,
            "and makes one, rows are \(browser.listedNames.joined(separator: ", "))")

        expect(browser.clickContextMenuItem("New File"), "New File is there too")
        settle(until: { browser.rowIndex(of: "untitled.txt") != nil }, seconds: 5)
        expect(
            browser.rowIndex(of: "untitled.txt") != nil,
            "and makes one, rows are \(browser.listedNames.joined(separator: ", "))")

        // Twice, because the number goes before the extension and getting that
        // wrong produces "untitled.txt 2", which is a name with a space and a
        // digit inside its extension.
        expect(browser.clickContextMenuItem("New File"), "asked for a second file")
        settle(until: { browser.rowIndex(of: "untitled 2.txt") != nil }, seconds: 5)
        expect(
            browser.rowIndex(of: "untitled 2.txt") != nil,
            "the second is untitled 2.txt, rows are \(browser.listedNames.joined(separator: ", "))")

        try? FileManager.default.removeItem(at: made)
    }

    /// A double click on a folder goes into it.
    ///
    /// There was no check for this at all, which is how it could be broken in
    /// a whole tree without anything noticing. Return runs the same code, so
    /// this covers both.
    private static func openingFolders(in window: BrowserWindow, fixture: URL) {
        let browser = window.browser
        let manager = FileManager.default
        let inside = fixture.appendingPathComponent("openable")
        try? manager.createDirectory(at: inside, withIntermediateDirectories: true)
        manager.createFile(atPath: inside.appendingPathComponent("x.txt").path, contents: Data())

        browser.navigate(to: fixture)
        browser.refresh(nil)
        settle(until: { browser.rowIndex(of: "openable") != nil })

        guard let row = browser.rowIndex(of: "openable") else {
            failures += 1
            print("  FAIL the folder to open is listed")
            return
        }
        // The two things that were actually wrong, asked directly. A synthetic
        // double click cannot be checked here: NSTableView's mouseDown runs a
        // tracking loop waiting for a mouse-up only the window server can
        // deliver, so driving it hangs.
        expect(
            !browser.hasEditableColumn,
            "no column claims to be editable, which is what silences doubleAction")

        // That the table is wired to us at all, which is the part a patch
        // removed and this restores.
        let wiring = browser.doubleClickWiring
        expect(
            wiring.action == #selector(BrowserViewController.openSelection),
            "the table's double-click action is the one that opens things, got "
                + (wiring.action.map(NSStringFromSelector) ?? "none"))
        expect(wiring.target === browser, "and it is sent to this window")
        expect(
            !browser.wouldBeginEditing(row: row),
            "and clicking an already-selected row does not start a rename, "
                + "which is what ate the click")

        browser.selectRange(row..<(row + 1))
        browser.activateSelection()
        settle(until: { browser.listedDirectory?.path == inside.path }, seconds: 5)
        expect(
            same(browser.currentDirectory, inside),
            "a double click on a folder goes into it, got \(browser.currentDirectory.path)")

        // And again with a reload in flight, which is the state the real one
        // was in when it took three tries. The listing is read on a worker, so
        // this cannot promise the reload lands exactly between the two clicks
        // — what it does promise is that one being under way does not stop the
        // click working.
        browser.navigate(to: fixture)
        settle(until: { browser.rowIndex(of: "openable") != nil })
        guard let again = browser.rowIndex(of: "openable") else { return }
        browser.reloadAsWatcherWould()
        browser.selectRange(again..<(again + 1))
        browser.activateSelection()
        settle(until: { browser.listedDirectory?.path == inside.path }, seconds: 5)
        expect(
            same(browser.currentDirectory, inside),
            "and still does with a reload in flight, got " + browser.currentDirectory.path)

        // Two rows picked, then one of them double-clicked: both open, the way
        // it does everywhere else. Forcing the selection down to the row under
        // the pointer would have thrown the other one away.
        browser.navigate(to: fixture)
        settle(until: { browser.rowIndex(of: "openable") != nil })
        if browser.rowCount >= 2 {
            browser.selectRange(0..<2)
            let picked = browser.selectedNames
            browser.activateSelection()
            settle(seconds: 0.4)
            expect(
                browser.selectedNames == picked || browser.listedDirectory?.path != fixture.path,
                "a double click inside a selection keeps it, had \(picked.count)")
        }

        // Nothing may rebuild the table while somebody is clicking in it. A
        // rebuild replaces the cell views, and a cell replaced under the
        // pointer ends the click sequence in progress: in a cloud folder the
        // measurements arrive in a trickle and a double click had to be tried
        // three times before one landed between two of them.
        browser.navigate(to: fixture)
        settle(until: { browser.listedDirectory?.path == fixture.path })
        // By name, so a re-sort by a size that arrives later cannot be mistaken
        // for a rebuild nobody asked for.
        browser.clickColumnHeader("name")
        settle(seconds: 1)
        let quiet = browser.reloadCount

        // What the watcher asks for, which is only that the listing be read
        // again. Deliberately not refresh, which also throws the measured
        // folder sizes away and has every right to redraw.
        browser.reloadAsWatcherWould()
        settle(seconds: 1.5)
        expect(
            browser.reloadCount == quiet,
            "a reload that changes nothing rebuilds nothing, \(quiet) then "
                + "\(browser.reloadCount)")

        // And the measurements landing afterwards must not do it either.
        let afterSizes = browser.reloadCount
        settle(seconds: 2)
        expect(
            browser.reloadCount == afterSizes,
            "nor do the folder sizes arriving, \(afterSizes) then \(browser.reloadCount)")

        // And on a folder somebody names, which is how a tree that behaves
        // differently — a cloud mount, a network share — gets looked at
        // without inventing one that cannot be made on a runner.
        guard let named = ProcessInfo.processInfo.environment["PFADI_CHECK_FOLDER"] else { return }
        let target = URL(fileURLWithPath: named)
        print("  ..   and in \(target.path)")

        browser.navigate(to: target)
        settle(until: { browser.listedDirectory?.path == target.path }, seconds: 15)
        expect(
            browser.rowCount > 0,
            "it lists something, got \(browser.rowCount) rows")

        guard let folder = browser.firstFolderName else {
            // Not a failure. Somebody pointed this at a folder with no folders
            // in it, and reporting that as a defect in pfadi would be noise
            // about the environment rather than about the code.
            print("  ..   no folder inside it to open, skipped")
            return
        }
        guard let namedRow = browser.rowIndex(of: folder) else { return }
        browser.selectRange(namedRow..<(namedRow + 1))
        browser.activateSelection()

        let expected = target.appendingPathComponent(folder)
        settle(until: { browser.listedDirectory?.path == expected.path }, seconds: 15)
        expect(
            same(browser.currentDirectory, expected),
            "opening \(folder) goes into it, got \(browser.currentDirectory.path)")
        expect(
            browser.listedDirectory?.path == expected.path,
            "and it is listed, got \(browser.listedDirectory?.path ?? "nothing")")
    }

    /// Show in Finder has to reach Finder.
    ///
    /// The polite call, `activateFileViewerSelecting`, honours the NSFileViewer
    /// preference. Once `pfadi-default apply` points that at pfadi, the menu
    /// item inside pfadi opened pfadi: a command that does nothing and looks
    /// like a bug.
    ///
    /// Checked by asking who took the request, not by looking for a window.
    /// A window title needs Screen Recording permission, which a CI runner does
    /// not have and a file browser should never ask for — the first version of
    /// this check did look, passed here and failed there.
    private static func showingInFinder(in window: BrowserWindow, fixture: URL) {
        let browser = window.browser
        browser.navigate(to: fixture)
        settle(until: { browser.listedDirectory?.path == fixture.path })

        // Nothing selected, so the target is the folder on screen rather than
        // whichever row the check before this one left highlighted.
        browser.clearSelection()

        let before = pfadiWindowCount()
        var receiver: String?
        var answered = false
        browser.showInFinder { identifier in
            receiver = identifier
            answered = true
        }
        settle(until: { answered }, seconds: 10)

        expect(answered, "the request was answered")
        expect(
            receiver == "com.apple.finder",
            "and Finder took it, got \(receiver ?? "nobody")")

        // The thing that was wrong: another window here, on the same folder,
        // in the application the person is already looking at.
        expect(
            pfadiWindowCount() == before,
            "no second pfadi window, had \(before) and now \(pfadiWindowCount())")
    }

    /// How many windows this application has, asked of the application itself.
    ///
    /// `NSApp.windows` rather than the system window list, which needs a
    /// permission to say anything useful.
    private static func pfadiWindowCount() -> Int {
        NSApp.windows.filter(\.isVisible).count
    }

    /// Clicking a column header, which is the only way anybody sorts anything.
    private static func sorting(in window: BrowserWindow, fixture: URL) {
        let browser = window.browser
        let manager = FileManager.default
        let folder = fixture.appendingPathComponent("sortable")
        try? manager.removeItem(at: folder)
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)

        // Deliberately in an order where name, size and date all disagree.
        // Named so that name order and size order disagree: with the sizes
        // ascending as zulu, alpha, mike, a check of the name header that
        // expected the size order would pass without the header working.
        for (name, bytes) in [("mike.bin", 64), ("zulu.bin", 40_000), ("alpha.bin", 4_000)] {
            manager.createFile(
                atPath: folder.appendingPathComponent(name).path,
                contents: Data(repeating: 0x61, count: bytes))
        }

        browser.navigate(to: folder)
        settle(until: { browser.listedDirectory?.path == folder.path && browser.rowCount == 3 })
        expect(browser.rowCount == 3, "three files to sort, got \(browser.rowCount)")

        expect(browser.clickColumnHeader("size"), "the size header can be clicked")
        settle(until: { browser.listedNames.first == "mike.bin" }, seconds: 3)
        expect(
            browser.listedNames == ["mike.bin", "alpha.bin", "zulu.bin"],
            "smallest first, got \(browser.listedNames.joined(separator: " "))")

        expect(browser.clickColumnHeader("size"), "and clicked again")
        settle(until: { browser.listedNames.first == "zulu.bin" }, seconds: 3)
        expect(
            browser.listedNames == ["zulu.bin", "alpha.bin", "mike.bin"],
            "largest first, got \(browser.listedNames.joined(separator: " "))")

        expect(browser.clickColumnHeader("name"), "the name header too")
        settle(until: { browser.listedNames.first == "alpha.bin" }, seconds: 3)
        expect(
            browser.listedNames == ["alpha.bin", "mike.bin", "zulu.bin"],
            "by name, which is a different order, got "
                + browser.listedNames.joined(separator: " "))

        expect(browser.clickColumnHeader("modified"), "and the modified header")
        settle(seconds: 0.5)
        expect(
            browser.listedNames.count == 3,
            "which still lists everything, got \(browser.listedNames.count)")

        // Folders have to sort by size too. Before they were measured they had
        // no size at all, so they stayed pinned to the top in name order and
        // sorting by size looked like it did nothing.
        let manager2 = FileManager.default
        for (name, bytes) in [("a-big", 30_000), ("z-small", 100)] {
            let sub = folder.appendingPathComponent(name)
            try? manager2.createDirectory(at: sub, withIntermediateDirectories: true)
            manager2.createFile(
                atPath: sub.appendingPathComponent("payload.bin").path,
                contents: Data(repeating: 0x61, count: bytes))
        }
        browser.refresh(nil)
        settle(until: { browser.rowIndex(of: "z-small") != nil })

        expect(browser.clickColumnHeader("size"), "sorted by size again")
        settle(until: { browser.listedNames.first == "z-small" }, seconds: 8)
        expect(
            Array(browser.listedNames.prefix(2)) == ["z-small", "a-big"],
            "the small folder sorts above the big one, got "
                + browser.listedNames.prefix(2).joined(separator: " "))

        expect(browser.clickColumnHeader("size"), "and the other way round")
        settle(until: { browser.listedNames.first == "a-big" }, seconds: 8)
        expect(
            Array(browser.listedNames.prefix(2)) == ["a-big", "z-small"],
            "the big one on top, got " + browser.listedNames.prefix(2).joined(separator: " "))

        // Created is covered by the header-menu check below, which goes
        // through the same gate every other column does.
        headerMenu(in: window)
        pathBarClicks(in: window, fixture: fixture)
        refusedTrash(in: window)
    }

    /// The right-click menu on the column headers, and what it offers.
    private static func headerMenu(in window: BrowserWindow) {
        let browser = window.browser
        let before = browser.visibleColumns
        expect(
            before.contains("name"), "the name column is on, got \(before.joined(separator: " "))")

        // Through the header view's own right-click handling, not by reading
        // the menu property. Those are different questions, and the difference
        // is the whole bug: `menu(for:)` handed the menu back while a
        // two-finger tap on the real headers did nothing, because
        // NSTableHeaderView takes the right button for itself.
        guard let menu = browser.headerMenuForRightClick() else {
            failures += 1
            print("  FAIL a right-click on the column headers opens a menu")
            return
        }
        expect(true, "a right-click on the column headers opens a menu")

        // Everything there is, not only the four it started with.
        let offered = Set(menu.items.compactMap { $0.representedObject as? String })
        for column in ListingColumn.allCases {
            expect(offered.contains(column.rawValue), "\(column.title) is in the menu")
        }

        // On, and off again.
        expect(browser.pickColumnFromHeaderMenu(.permissions), "Permissions can be picked")
        expect(
            browser.visibleColumns.contains("permissions"),
            "and appears, got \(browser.visibleColumns.joined(separator: " "))")
        settle(seconds: 0.6)
        expect(
            browser.cellText(row: 0, column: .permissions).hasPrefix("d")
                || browser.cellText(row: 0, column: .permissions).hasPrefix("-"),
            "with something that reads like a mode, got "
                + browser.cellText(row: 0, column: .permissions))

        expect(browser.pickColumnFromHeaderMenu(.owner), "Owner too")
        settle(seconds: 0.6)
        expect(
            !browser.cellText(row: 0, column: .owner).isEmpty,
            "and it names somebody, got \(browser.cellText(row: 0, column: .owner))")

        expect(browser.pickColumnFromHeaderMenu(.kind), "and Kind")
        settle(seconds: 0.6)
        expect(
            !browser.cellText(row: 0, column: .kind).isEmpty,
            "which the system fills in, got \(browser.cellText(row: 0, column: .kind))")

        for column in [ListingColumn.permissions, .owner, .kind] {
            browser.pickColumnFromHeaderMenu(column)
        }

        // Name has to stay: a list of sizes and dates with nothing saying
        // which file they belong to is not a list.
        browser.pickColumnFromHeaderMenu(.name)
        expect(browser.visibleColumns.contains("name"), "the name column cannot be hidden")
        expect(
            browser.bannerMessage.contains("name column"),
            "and says so where somebody will see it, got \(browser.bannerMessage)")

        expect(
            browser.visibleColumns == before,
            "everything is back as it was, got \(browser.visibleColumns.joined(separator: " "))")
    }

    /// Double-clicking a folder in the path bar.
    ///
    /// It was written to navigate and could never run: the sibling menu opened
    /// on the first click and took the second one with it.
    private static func pathBarClicks(in window: BrowserWindow, fixture: URL) {
        let browser = window.browser
        let parent = fixture.deletingLastPathComponent()

        browser.navigate(to: fixture)
        settle(until: { browser.listedDirectory?.path == fixture.path })

        expect(
            browser.clickPathComponent(parent.path, clicks: 2),
            "the enclosing folder is in the bar")
        expect(
            same(browser.currentDirectory, parent),
            "a double click goes straight there, got \(browser.currentDirectory.path)")
        expect(
            !browser.isPathMenuPending,
            "and no menu was left waiting to open on top of it")
    }

    /// Trashing a selection where the system refuses part of it.
    private static func refusedTrash(in window: BrowserWindow) {
        let browser = window.browser
        let home = FileManager.default.homeDirectoryForCurrentUser

        // A real one, made here, beside one macOS will not give up. Trashing
        // used to stop at the first refusal, so the file that could have gone
        // stayed put and the message was about the whole selection.
        let mine = home.appendingPathComponent(
            "pfadi-check-\(ProcessInfo.processInfo.processIdentifier).txt")
        FileManager.default.createFile(atPath: mine.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: mine) }

        browser.navigate(to: home)
        settle(until: { browser.rowIndex(of: mine.lastPathComponent) != nil }, seconds: 5)

        guard let mineRow = browser.rowIndex(of: mine.lastPathComponent),
            let documentsRow = browser.rowIndex(of: "Documents")
        else {
            failures += 1
            print("  FAIL both the file and Documents are listed in home")
            return
        }

        browser.selectRange(mineRow..<(mineRow + 1))
        browser.addToSelection(row: documentsRow)
        expect(browser.selectedNames.count == 2, "both are selected")

        browser.moveToTrash(nil)
        settle(seconds: 1)

        expect(
            !FileManager.default.fileExists(atPath: mine.path),
            "the one that could go, went")
        expect(
            FileManager.default.fileExists(atPath: home.appendingPathComponent("Documents").path),
            "and Documents is still there")
        expect(
            browser.statusLine.contains("Documents"),
            "the message names what was refused, got \(browser.statusLine)")
        expect(
            browser.statusLine.contains("macOS does not let"),
            "and says why rather than quoting a permission error")

        // The status line is eleven points of grey at the bottom of the
        // window. A refusal reported only there reads, from where anybody is
        // looking, as nothing having happened.
        expect(
            browser.bannerMessage.contains("Documents"),
            "the banner says it too, got \(browser.bannerMessage)")

        // And it goes when you leave, rather than following you into a folder
        // it has nothing to do with.
        browser.navigate(to: FileManager.default.temporaryDirectory)
        settle(seconds: 0.4)
        expect(browser.bannerMessage.isEmpty, "and clears on the way out")
    }

    /// Dropping several files at once, copy and move.
    ///
    /// The drag itself is AppKit's: it asks for one pasteboard writer per
    /// selected row, so a five-row drag really does arrive with five URLs. What
    /// is checked here is everything after that, which is ours.
    private static func dropping(in window: BrowserWindow, fixture: URL) {
        let browser = window.browser
        let manager = FileManager.default
        let source = fixture.appendingPathComponent("from")
        let into = fixture.appendingPathComponent("into")
        try? manager.createDirectory(at: source, withIntermediateDirectories: true)
        try? manager.createDirectory(at: into, withIntermediateDirectories: true)

        let files = ["one.txt", "two.txt", "three.txt"].map {
            source.appendingPathComponent($0)
        }
        for file in files { manager.createFile(atPath: file.path, contents: Data("x".utf8)) }

        browser.navigate(to: fixture)
        // For the row, not for the folder: this window is already showing this
        // folder, so waiting on `listedDirectory` is satisfied at once by the
        // listing taken before these folders were made.
        browser.refresh(nil)
        settle(until: { browser.rowIndex(of: "into") != nil })

        // Dropping on a folder row targets that folder; dropping between rows
        // targets the folder on screen.
        guard let intoRow = browser.rowIndex(of: "into") else {
            failures += 1
            print("  FAIL the destination folder is in the list")
            return
        }
        // Resolved on both sides: the listing's URLs come back through
        // /private/var and the fixture's do not, because /var is a symlink.
        // Comparing the two spellings is a check failing over nothing.
        let onFolder = browser.dropDestination(row: intoRow, operation: .on)
        expect(
            same(onFolder, into),
            "a drop on a folder row goes into that folder, got \(onFolder.path)")
        expect(
            same(browser.dropDestination(row: intoRow, operation: .above), fixture),
            "and a drop between rows goes into the folder on screen")

        expect(
            browser.drop(files, into: into, kind: .copy),
            "three files dropped at once are accepted")
        settle(until: { browser.statusLine.contains("3 items") }, seconds: 10)
        expect(
            browser.statusLine.contains("3 items"),
            "and all three arrive, got \(browser.statusLine)")
        expect(
            (try? manager.contentsOfDirectory(atPath: into.path).count) == 3,
            "which is what is actually on the disk")

        // And a move, because that is the other half of a drag and it is the
        // half that can lose files rather than merely duplicate them.
        let elsewhere = fixture.appendingPathComponent("moved")
        try? manager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        expect(
            browser.drop(files, into: elsewhere, kind: .move),
            "and three moved at once are accepted too")
        settle(
            until: { (try? manager.contentsOfDirectory(atPath: elsewhere.path).count) == 3 },
            seconds: 10)
        expect(
            (try? manager.contentsOfDirectory(atPath: elsewhere.path).count) == 3,
            "all three arrive")
        expect(
            (try? manager.contentsOfDirectory(atPath: source.path).count) == 0,
            "and none is left behind where they came from")
    }

    /// What another application's "Reveal in Finder" ends up doing here.
    ///
    /// The path it takes is the same one: a URL arrives, the delegate decides
    /// what it means, and the window is asked to show it. Going through
    /// `AppDelegate.target(for:)` rather than calling `reveal` directly is the
    /// point — the decision is the part that was worth getting wrong.
    private static func revealing(in window: BrowserWindow, fixture: URL) {
        let browser = window.browser
        let file = fixture.appendingPathComponent("notes.txt")

        // From somewhere else entirely, so this is not passing because the
        // folder was already on screen — and deliberately WITHOUT waiting for
        // that listing to arrive. A reveal asked for while a navigation is in
        // flight is the case that was broken: what is drawn and where we are
        // going disagree, and the shortcut in reveal took the first for the
        // second. It passed here and failed on a runner, which is slower.
        browser.navigate(to: FileManager.default.homeDirectoryForCurrentUser)

        guard let target = AppDelegate.target(for: PfadiURL.reveal(file)) else {
            failures += 1
            print("  FAIL a pfadi://reveal URL is understood")
            return
        }
        expect(target == .file(file.standardizedFileURL), "a reveal URL names the file")

        window.go(to: target)
        settle(until: { browser.selectedName == "notes.txt" })
        expect(
            browser.currentDirectory.path == fixture.path,
            "revealing opens the folder holding it, got \(browser.currentDirectory.path)")
        expect(
            browser.selectedName == "notes.txt",
            "and selects the file, got \(browser.selectedName ?? "nothing")")

        // A plain file URL, which is what a drop on the Dock icon sends.
        let dropped = AppDelegate.target(for: fixture.appendingPathComponent("report.txt"))
        expect(dropped != nil, "a dropped file is understood too")
        if let dropped {
            window.go(to: dropped)
            settle(until: { browser.selectedName == "report.txt" })
            expect(browser.selectedName == "report.txt", "and it is the one selected")
        }

        // A folder URL means open, not select. The two are indistinguishable
        // once they are both file URLs, which is why the scheme exists.
        expect(
            AppDelegate.target(for: fixture) == .directory(PathCompletion.directoryURL(fixture)),
            "a folder URL still means open it")
    }

    /// Folder sizes: measured for what is on screen, and nothing blocking.
    private static func sizing(in window: BrowserWindow, fixture: URL) {
        let browser = window.browser
        let manager = FileManager.default
        let sub = fixture.appendingPathComponent("measured")
        try? manager.createDirectory(at: sub, withIntermediateDirectories: true)
        try? Data(repeating: 0x61, count: 8192)
            .write(to: sub.appendingPathComponent("payload.bin"))

        browser.refresh(nil)
        settle(until: { browser.rowCount == 5 })
        expect(browser.rowCount == 5, "the new folder is listed, got \(browser.rowCount)")

        settle(until: { browser.measuredSize(of: "measured") != nil }, seconds: 5)
        guard let measured = browser.measuredSize(of: "measured") else {
            failures += 1
            print("  FAIL the folder on screen gets measured")
            return
        }
        expect(measured.complete, "a small folder is measured completely")
        expect(
            measured.bytes >= 8192,
            "and reports what is in it, got \(measured.bytes) of at least 8192")

        // Left in place: the whole fixture goes at the end of behaviour(), and
        // deleting it here pulled a row out from under the selection check
        // that runs next, which then failed for the wrong reason.
    }

    /// Whether two icons draw the same thing.
    ///
    /// Rendered into identical bitmaps rather than compared as TIFF data. An
    /// NSImage carries many representations, `icon(forFile:)` hands back a
    /// shared instance, and setting `size` on one mutates it for everybody —
    /// so comparing the data compares bookkeeping as much as pixels, and did:
    /// the same pair matched here and differed on a runner.
    private static func sameImage(_ left: NSImage, _ right: NSImage) -> Bool {
        guard let a = pixels(of: left), let b = pixels(of: right) else { return false }
        return a == b
    }

    private static func pixels(of image: NSImage) -> Data? {
        let size = NSSize(width: 32, height: 32)
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // A copy, so the shared instance NSWorkspace handed over is not
        // resized underneath whoever else is drawing it.
        let copy = image.copy() as? NSImage ?? image
        copy.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    /// Whether two URLs are the same place, symlinks and all.
    private static func same(_ left: URL, _ right: URL) -> Bool {
        left.resolvingSymlinksInPath().path == right.resolvingSymlinksInPath().path
    }

    private static func ambiguousViews(in view: NSView?) -> [String] {
        guard let view else { return [] }
        var found: [String] = []
        if view.hasAmbiguousLayout {
            found.append(String(describing: type(of: view)))
        }
        for subview in view.subviews {
            found += ambiguousViews(in: subview)
        }
        return found
    }

    /// A folder with known contents, so the counts below mean something
    /// wherever this runs.
    private static func makeFixture() -> URL? {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pfadi-check-\(ProcessInfo.processInfo.processIdentifier)")
        let manager = FileManager.default
        try? manager.removeItem(at: root)
        guard (try? manager.createDirectory(at: root, withIntermediateDirectories: true)) != nil
        else { return nil }

        // Two that the filter should find, one it should not, and a dotfile
        // that is only there at all because dotfiles are shown by default.
        for name in ["report.txt", "report-2.txt", "notes.txt", ".hidden"] {
            manager.createFile(
                atPath: root.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        return URL(fileURLWithPath: root.path, isDirectory: true)
    }

    /// Lets the listing arrive.
    ///
    /// Reading a folder happens on a worker and is applied on the main queue,
    /// which is the whole point: a slow mount must not freeze the window. That
    /// also means nothing arrives unless the main queue is turning, and in a
    /// check there is no run loop doing it.
    private static func settle(until ready: () -> Bool = { false }, seconds: Double = 2) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if ready() { return }
        }
    }

    private static func expect(_ condition: Bool, _ what: String) {
        if condition {
            print("  ok   \(what)")
        } else {
            failures += 1
            print("  FAIL \(what)")
        }
    }
}
