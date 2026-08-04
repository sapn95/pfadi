import AppKit
import PfadiCore

/// The list of favourite folders down the left.
final class SidebarViewController: NSViewController {
    var onSelect: ((URL) -> Void)?

    private let favourites: Favourites
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let tableView = NSTableView()
    private var rows: [URL] = []

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
        rows = favourites.visible
        tableView.reloadData()
    }

    @objc private func removeClickedRow(_ sender: Any?) {
        // clickedRow, not selectedRow: a right-click does not move the
        // selection, so removing the selected row would delete the wrong one.
        let row = tableView.clickedRow
        guard rows.indices.contains(row) else { return }
        favourites.remove(rows[row])
        reload()
    }
}

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let url = rows[row]

        let id = NSUserInterfaceItemIdentifier("favouriteCell")
        let cell =
            tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
            ?? Self.makeCell(id: id)

        cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
        cell.textField?.stringValue = Favourites.title(for: url, home: home)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard rows.indices.contains(row) else { return }
        onSelect?(rows[row])
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
