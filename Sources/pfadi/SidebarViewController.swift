import AppKit
import PfadiCore

/// The list of favourite folders down the left.
final class SidebarViewController: NSViewController {
    var onSelect: ((URL) -> Void)?
    /// A share to reconnect to, or nil to ask for one.
    var onConnect: ((URL?) -> Void)?
    /// Files dropped onto a folder row, to be copied or moved into it.
    var onDrop: ((_ sources: [URL], _ destination: URL) -> Void)?

    private let favourites: Favourites
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let tableView = NSTableView()
    private let searchField = NSSearchField()
    private var rows: [Row] = []
    /// Everything there is, before the filter narrows it. Kept so typing does
    /// not have to ask the kernel for the mounted volumes again on every
    /// keystroke.
    private var allRows: [Row] = []
    private var query = ""

    /// A sidebar is a list of headings and things under them, and AppKit's
    /// table wants one flat array, so the two are spelled out as one type.
    private enum Row {
        /// Which section a row came from, so removing one only offers to
        /// remove the kind that is actually yours to remove.
        enum Section {
            case recents
            case favourites
            case cloud
            case locations
            case servers
        }

        case heading(String)
        case place(URL, title: String, section: Section)
        /// The last row: the way in to a share that is not mounted yet.
        case connect

        var url: URL? {
            if case .place(let url, _, _) = self { return url }
            return nil
        }

        var section: Section? {
            if case .place(_, _, let section) = self { return section }
            return nil
        }

        var isSelectable: Bool {
            if case .heading = self { return false }
            return true
        }
    }

    init(favourites: Favourites) {
        self.favourites = favourites
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("pfadi builds its views in code")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 190, height: 560))

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = tableView

        // .sourceList is what gives a sidebar its translucency, its row
        // highlight and its inset, without drawing any of that by hand.
        tableView.style = .sourceList
        tableView.rowHeight = 26
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("favourite"))
        column.width = 170
        tableView.addTableColumn(column)

        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

        let menu = NSMenu()
        menu.addItem(
            withTitle: "Remove from Favourites",
            action: #selector(removeClickedRow(_:)),
            keyEquivalent: ""
        )
        tableView.menu = menu

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Filter"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))

        view.addSubview(searchField)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            // Above the list rather than floating over it: thirty favourites is
            // exactly when you need to see both the box and what it left.
            searchField.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        reload()
    }

    /// Cloud folders and volumes, kept between reloads.
    ///
    /// Finding them means listing a directory and asking the kernel for every
    /// mounted filesystem, and the second of those can block for a long time on
    /// a share whose server has gone away. Doing it on every navigation would
    /// put that hang in the middle of walking around a folder tree.
    private var discovered: (cloud: [URL], volumes: [URL])?

    /// What is actually drawn, for the checks. A sidebar that is right in the
    /// model and wrong on screen is the failure this exists to catch.
    func drawnRows() -> [String] {
        rows.map { row in
            switch row {
            case .heading(let title): return "[\(title)]"
            case .place(_, let title, _): return title
            case .connect: return "(connect)"
            }
        }
    }

    /// Selects the row for a folder, for the checks.
    ///
    /// By URL rather than by title: the same folder can appear under Recents
    /// and under Favourites, and two rows with one name is exactly the case a
    /// check should not be ambiguous about.
    ///
    /// Selecting is all it does. AppKit posts the selection notification for a
    /// programmatic change too, so calling the delegate here as well would run
    /// the navigation twice.
    @discardableResult
    func clickRow(at url: URL) -> Bool {
        guard let index = rows.firstIndex(where: { $0.url?.path == url.path }) else {
            return false
        }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        return true
    }

    func reload(rediscover: Bool = false) {
        if rediscover || discovered == nil {
            discovered = (favourites.cloudLocations(), favourites.volumes())
        }
        var built: [Row] = []

        let recents = favourites.recents()
        if !recents.isEmpty {
            built.append(.heading("Recents"))
            built += recents.map {
                .place($0, title: Favourites.title(for: $0, home: home), section: .recents)
            }
        }

        let favouriteRows = favourites.visible
        if !favouriteRows.isEmpty {
            built.append(.heading("Favourites"))
            built += favouriteRows.map {
                .place($0, title: Favourites.title(for: $0, home: home), section: .favourites)
            }
        }

        // Discovered, not configured, and rebuilt on every reload: a share can
        // be mounted and a cloud folder can be signed out of while the window
        // is open.
        let cloud = discovered?.cloud ?? []
        if !cloud.isEmpty {
            built.append(.heading("Cloud"))
            built += cloud.map {
                .place($0, title: Favourites.cloudTitle(for: $0), section: .cloud)
            }
        }

        let volumes = discovered?.volumes ?? []
        if !volumes.isEmpty {
            built.append(.heading("Locations"))
            built += volumes.map { .place($0, title: $0.lastPathComponent, section: .locations) }
        }

        // Always present, even with nothing under it. A way to reach a share
        // that only appears once you already have one is no way in at all.
        built.append(.heading("Servers"))
        built += favourites.servers().map {
            .place($0, title: $0.host ?? $0.absoluteString, section: .servers)
        }
        built.append(.connect)

        allRows = built
        applyFilter()
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        query = sender.stringValue.trimmingCharacters(in: .whitespaces)
        applyFilter()
    }

    /// Narrows the sidebar to what was typed, headings and all.
    ///
    /// The same match every other filter in pfadi uses, so `dwn` finds
    /// Downloads here exactly as it does in the file list. Ranked, because a
    /// sidebar has no sort order of its own to protect — but only within a
    /// section, so a favourite cannot jump above a heading it does not belong
    /// under.
    private func applyFilter() {
        guard !query.isEmpty else {
            rows = allRows
            tableView.reloadData()
            return
        }

        var narrowed: [Row] = []
        var section: [Row] = []
        var heading: Row?

        func flush() {
            let kept = FuzzyMatch.filter(section, query: query) { row in
                if case .place(_, let title, _) = row { return title }
                return ""
            }
            // A heading with nothing under it says only that a section exists,
            // which is not what somebody filtering wants to read.
            guard !kept.isEmpty else { return }
            if let heading { narrowed.append(heading) }
            narrowed += kept
        }

        for row in allRows {
            switch row {
            case .heading:
                flush()
                heading = row
                section = []
            case .place:
                section.append(row)
            case .connect:
                // Always reachable, whatever was typed: a way in that
                // disappears when you search is not a way in.
                continue
            }
        }
        flush()

        if narrowed.isEmpty {
            narrowed.append(.heading("No match"))
        }
        narrowed.append(.connect)

        rows = narrowed
        tableView.reloadData()
    }

    /// Types into the sidebar's filter, for the checks.
    func filter(by text: String) {
        searchField.stringValue = text
        searchChanged(searchField)
    }

    @objc private func removeClickedRow(_ sender: Any?) {
        // clickedRow, not selectedRow: a right-click does not move the
        // selection, so removing the selected row would delete the wrong one.
        let row = tableView.clickedRow
        guard rows.indices.contains(row), let url = rows[row].url else { return }
        // Only a favourites row, and by which section it is in rather than by
        // whether the folder happens to also be a favourite: a cloud folder
        // that was favourited must not be removable from its Cloud row.
        guard rows[row].section == .favourites else {
            NSSound.beep()
            return
        }
        favourites.remove(url)
        reload()
    }
}

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .heading = rows[row] { return 22 }
        return 26
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }

        switch rows[row] {
        case .heading(let title):
            let id = NSUserInterfaceItemIdentifier("headingCell")
            let cell =
                tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
                ?? Self.makeHeadingCell(id: id)
            cell.textField?.stringValue = title
            return cell

        case .connect:
            let id = NSUserInterfaceItemIdentifier("favouriteCell")
            let cell =
                tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
                ?? Self.makeCell(id: id)
            cell.imageView?.image = NSImage(
                systemSymbolName: "network", accessibilityDescription: nil)
            cell.textField?.stringValue = "Connect to Server…"
            return cell

        case .place(let url, let title, _):
            let id = NSUserInterfaceItemIdentifier("favouriteCell")
            let cell =
                tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
                ?? Self.makeCell(id: id)
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
            cell.textField?.stringValue = title
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .heading = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].isSelectable
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard rows.indices.contains(row) else { return }

        switch rows[row] {
        case .connect:
            onConnect?(nil)
        case .place(let url, _, .servers):
            onConnect?(url)
        case .place(let url, _, _):
            onSelect?(url)
        case .heading:
            break
        }
    }

    private static func makeHeadingCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor

        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private static func makeCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 13)

        cell.addSubview(icon)
        cell.addSubview(label)
        cell.imageView = icon
        cell.textField = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - Drag and drop

extension SidebarViewController {
    /// A favourite can be dragged: out of the window as a folder, or up and
    /// down its own section to reorder it.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
        -> (any NSPasteboardWriting)?
    {
        guard rows.indices.contains(row), rows[row].section == .favourites,
            let url = rows[row].url
        else { return nil }
        return url as NSURL
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation operation: NSTableView.DropOperation
    ) -> NSDragOperation {
        let sources = draggedURLs(info)
        guard !sources.isEmpty else { return [] }

        // Onto a folder row: put the files in that folder.
        if operation == .on, rows.indices.contains(row), let destination = rows[row].url,
            rows[row].section != .servers, isFolder(destination)
        {
            return info.draggingSource as AnyObject? === tableView ? [] : .copy
        }

        // Between rows inside Favourites: add it, or move it if it is already
        // there. Only folders, because a file in a folder list is not a place.
        if operation == .above, favouritesRange().contains(row),
            sources.allSatisfy({ isFolder($0) })
        {
            return info.draggingSource as AnyObject? === tableView ? .move : .copy
        }
        return []
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation operation: NSTableView.DropOperation
    ) -> Bool {
        let sources = draggedURLs(info)
        guard !sources.isEmpty else { return false }

        if operation == .on, rows.indices.contains(row), let destination = rows[row].url,
            isFolder(destination)
        {
            onDrop?(sources, destination)
            return true
        }

        guard operation == .above else { return false }
        // The row index counts headings too, so it has to come back to an
        // index within the favourites themselves before anything is inserted.
        let offset = row - favouritesRange().lowerBound
        for (index, url) in sources.filter(isFolder).enumerated() {
            favourites.insert(url, at: offset + index)
        }
        reload()
        return true
    }

    /// Where the favourites sit in the flat row list, including the position
    /// just past the last one so something can be dropped at the end.
    private func favouritesRange() -> Range<Int> {
        let indices = rows.indices.filter { rows[$0].section == .favourites }
        guard let first = indices.first, let last = indices.last else {
            // No favourites yet: the only place to drop is under the heading.
            guard
                let heading = rows.firstIndex(where: {
                    if case .heading(let title) = $0 { return title == "Favourites" }
                    return false
                })
            else { return 0..<0 }
            return (heading + 1)..<(heading + 2)
        }
        return first..<(last + 2)
    }

    private func draggedURLs(_ info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
    }

    private func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
