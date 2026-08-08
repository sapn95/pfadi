import AppKit
import PfadiCore

/// The servers you have connected to before, in the connect sheet.
///
/// This was an `NSPopUpButton`. It showed each server as its whole
/// `absoluteString`, replaced its own title with whatever was picked so the
/// label was gone after the first use, offered no way to remove anything, and
/// could only be reached with the mouse. With a dozen filers it was the worst
/// control in the application.
///
/// So: a list, with the same fuzzy filter every other list in pfadi has, the
/// same keyboard, and the same match — `dwn` finds Downloads here exactly as it
/// does in the sidebar.
final class KnownConnections: NSView {
    /// Told when a row is chosen, by click or by return.
    var onChoose: ((URL) -> Void)?

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let empty = NSTextField(labelWithString: "")

    private var all: [URL]
    private var shown: [URL]

    init(servers: [URL]) {
        all = servers
        shown = servers
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("pfadi builds its views in code")
    }

    /// What is on screen, for the checks.
    var drawnRows: [String] { shown.map(Self.title(for:)) }

    /// Types into the filter, for the checks.
    func filter(by text: String) {
        searchField.stringValue = text
        filterChanged(searchField)
    }

    /// Picks a row the way a double click does, for the checks.
    @discardableResult
    func chooseRow(_ row: Int) -> Bool {
        guard shown.indices.contains(row) else { return false }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        onChoose?(shown[row])
        return true
    }

    /// How a server reads in the list.
    ///
    /// `sapn@filer97.sbb.ch / projects`, not
    /// `smb://sapn@filer97.sbb.ch/projects`. The scheme is on the button above
    /// and repeating it in every row costs the width the share name needs.
    static func title(for url: URL) -> String {
        let user = url.user.map { "\($0)@" } ?? ""
        let share = NetworkShare.title(for: url)
        let host = url.host ?? url.absoluteString
        return share.isEmpty ? user + host : "\(user)\(host)  ·  \(share)"
    }

    private func build() {
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Filter \(all.count) known"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(filterChanged(_:))
        // Hidden until there are enough to be worth narrowing. A filter over
        // three rows is a control in the way.
        searchField.isHidden = all.count < 6

        tableView.style = .inset
        tableView.rowHeight = 22
        tableView.headerView = nil
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.addTableColumn(
            NSTableColumn(identifier: NSUserInterfaceItemIdentifier("server")))

        let menu = NSMenu()
        menu.addItem(
            withTitle: "Forget This Server", action: #selector(forgetClicked(_:)),
            keyEquivalent: ""
        ).target = self
        tableView.menu = menu

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = tableView

        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.font = .systemFont(ofSize: 11)
        empty.textColor = .secondaryLabelColor
        empty.isHidden = true

        addSubview(searchField)
        addSubview(scrollView)
        addSubview(empty)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(
                equalTo: searchField.isHidden ? topAnchor : searchField.bottomAnchor,
                constant: searchField.isHidden ? 0 : 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Four rows and a bit, so the list is obviously a list and does not
            // grow the sheet past the screen with thirty servers in it.
            scrollView.heightAnchor.constraint(equalToConstant: 96),

            empty.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    @objc private func filterChanged(_ sender: NSSearchField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespaces)
        // The same match as the sidebar, the path menu and the file list.
        shown = FuzzyMatch.filter(all, query: text) { Self.title(for: $0) }
        empty.stringValue = shown.isEmpty ? "no match" : ""
        empty.isHidden = !shown.isEmpty
        tableView.reloadData()
        if !shown.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    @objc private func rowDoubleClicked() {
        chooseRow(tableView.clickedRow)
    }

    @objc private func forgetClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard shown.indices.contains(row) else { return }
        let going = shown[row]

        all.removeAll { $0 == going }
        Favourites(preferences: Preferences()).forgetServer(going)
        filterChanged(searchField)
    }
}

extension KnownConnections: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard shown.indices.contains(row) else { return nil }

        let id = NSUserInterfaceItemIdentifier("serverCell")
        let cell =
            tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
            ?? Self.makeCell(id: id)

        cell.textField?.stringValue = Self.title(for: shown[row])
        // The whole address, for when two filers differ only in their path.
        cell.textField?.toolTip = shown[row].absoluteString
        cell.imageView?.image = NSImage(
            systemSymbolName: "externaldrive.connected.to.line.below",
            accessibilityDescription: nil)
        return cell
    }

    private static func makeCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingMiddle

        cell.addSubview(icon)
        cell.addSubview(label)
        cell.imageView = icon
        cell.textField = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
