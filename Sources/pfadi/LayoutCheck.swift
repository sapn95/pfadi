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

        behaviour()
        print(failures == 0 ? "\nall checks ok" : "\n\(failures) problems")
        exit(failures == 0 ? 0 : 1)
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

        created(in: window)
        headerMenu(in: window)
        pathBarClicks(in: window, fixture: fixture)
        refusedTrash(in: window)
    }

    /// The right-click menu on the column headers.
    private static func headerMenu(in window: BrowserWindow) {
        let browser = window.browser
        let before = browser.visibleColumns

        expect(
            before.contains("name"), "the name column is on, got \(before.joined(separator: " "))")

        expect(browser.clickHeaderMenuItem("modified"), "Modified is in the header menu")
        expect(
            !browser.visibleColumns.contains("modified"),
            "and picking it takes the column away, got \(browser.visibleColumns.joined(separator: " "))"
        )

        expect(browser.clickHeaderMenuItem("modified"), "picked again")
        expect(browser.visibleColumns.contains("modified"), "and it comes back")

        // Name has to stay: a list of sizes and dates with nothing saying
        // which file they belong to is not a list.
        browser.clickHeaderMenuItem("name")
        expect(
            browser.visibleColumns.contains("name"),
            "the name column cannot be hidden")
        expect(
            browser.bannerMessage.contains("name column"),
            "and says so where somebody will see it, got \(browser.bannerMessage)")

        expect(
            browser.visibleColumns == before,
            "everything is back as it was, got \(browser.visibleColumns.joined(separator: " "))")
    }

    /// The Created column: off unless asked for, and sortable once it is.
    private static func created(in window: BrowserWindow) {
        let browser = window.browser
        let wasShown = browser.showsCreatedColumn

        browser.toggleCreatedColumn(nil)
        expect(
            browser.showsCreatedColumn != wasShown,
            "⇧⌘K puts the created column on screen")

        if browser.showsCreatedColumn {
            expect(browser.clickColumnHeader("created"), "and its header sorts by it")
            settle(seconds: 0.5)
            expect(browser.rowCount > 0, "which still lists everything")
        }

        browser.toggleCreatedColumn(nil)
        expect(browser.showsCreatedColumn == wasShown, "and again puts it away")
        // Hiding the column it was sorted by has to leave a sort you can see.
        expect(browser.rowCount > 0, "with the list still in some order")
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
        // folder was already on screen.
        browser.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
        settle(seconds: 0.3)

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
