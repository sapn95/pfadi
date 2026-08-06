import AppKit

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
