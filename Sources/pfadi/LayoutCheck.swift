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

        print(failures == 0 ? "\nlayout ok" : "\n\(failures) layout problems")
        exit(failures == 0 ? 0 : 1)
    }

    private static func check(at size: NSSize) {
        print("\n\(Int(size.width))x\(Int(size.height))")

        let window = BrowserWindow(
            directory: FileManager.default.homeDirectoryForCurrentUser)
        window.window.setContentSize(size)
        window.window.layoutIfNeeded()

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

    private static func expect(_ condition: Bool, _ what: String) {
        if condition {
            print("  ok   \(what)")
        } else {
            failures += 1
            print("  FAIL \(what)")
        }
    }
}
