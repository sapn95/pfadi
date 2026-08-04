import AppKit
import PfadiCore

/// The list of favourite folders down the left.
final class SidebarViewController: NSViewController {
    var onSelect: ((URL) -> Void)?
    /// A share to reconnect to, or nil to ask for one.
    var onConnect: ((URL?) -> Void)?

    private let favourites: Favourites
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let tableView = NSTableView()
    private var rows: [Row] = []

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

        let menu = NSMenu()
        menu.addItem(
            withTitle: "Remove from Favourites",
            action: #selector(removeClickedRow(_:)),
            keyEquivalent: ""
        )
        tableView.menu = menu

        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        reload()
    }

    func reload() {
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
        let cloud = favourites.cloudLocations()
        if !cloud.isEmpty {
            built.append(.heading("Cloud"))
            built += cloud.map {
                .place($0, title: Favourites.cloudTitle(for: $0), section: .cloud)
            }
        }

        let volumes = favourites.volumes()
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

        rows = built
        tableView.reloadData()
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
