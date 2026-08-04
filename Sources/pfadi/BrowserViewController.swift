import AppKit
import PfadiCore

/// One window: a path field on top, a file list below, a count at the bottom.
final class BrowserViewController: NSViewController {
    private var directory: URL
    private var entries: [Entry] = []
    private var showHidden = false

    private let pathField = PathField()
    private let tableView = FileTableView()
    private let statusLabel = NSTextField(labelWithString: "")

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    init(directory: URL) {
        self.directory = PathCompletion.directoryURL(directory)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("pfadi builds its views in code")
    }

    // MARK: - View

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 560))

        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.target = self
        pathField.action = #selector(pathFieldCommitted(_:))

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = tableView

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        configureTable()

        view.addSubview(pathField)
        view.addSubview(scrollView)
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            pathField.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            pathField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            pathField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),

            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            statusLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
    }

    private func configureTable() {
        tableView.style = .inset
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelection)
        tableView.onReturn = { [weak self] in self?.openSelection() }

        addColumn(id: "name", title: "Name", width: 420)
        addColumn(id: "size", title: "Size", width: 90)
        addColumn(id: "modified", title: "Modified", width: 160)
    }

    private func addColumn(id: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        tableView.addTableColumn(column)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reload()
        view.window?.makeFirstResponder(tableView)
    }

    // MARK: - Navigation

    func navigate(to url: URL) {
        directory = PathCompletion.directoryURL(url)
        reload()
        view.window?.makeFirstResponder(tableView)
    }

    private func reload() {
        var failure: String?
        do {
            entries = try DirectoryListing.read(directory, showHidden: showHidden)
        } catch {
            // An unreadable directory is a normal event, not a crash: think
            // /Library/Caches, or anything behind a TCC prompt not yet granted.
            entries = []
            failure = "cannot read \(directory.path): \(error.localizedDescription)"
        }

        pathField.stringValue = directory.path
        pathField.showHidden = showHidden
        view.window?.title = directory.lastPathComponent.isEmpty ? "/" : directory.lastPathComponent
        tableView.reloadData()

        guard !entries.isEmpty else {
            statusLabel.stringValue = failure ?? "empty folder"
            return
        }

        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)
        let folders = entries.filter(\.isDirectory).count
        statusLabel.stringValue =
            "\(entries.count) items, \(folders) folders" + (showHidden ? ", hidden shown" : "")
    }

    @objc private func openSelection() {
        let row = tableView.selectedRow
        guard row >= 0, row < entries.count else { return }
        let entry = entries[row]
        if entry.isDirectory {
            navigate(to: entry.url)
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }

    @objc private func pathFieldCommitted(_ sender: NSTextField) {
        switch PathCompletion.resolve(sender.stringValue, relativeTo: directory) {
        case .directory(let url):
            navigate(to: url)
        case .file(let url):
            NSWorkspace.shared.open(url)
            pathField.stringValue = directory.path
        case nil:
            NSSound.beep()
        }
    }

    // MARK: - Menu actions

    @objc func focusPathField(_ sender: Any?) {
        view.window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
    }

    @objc func goToParent(_ sender: Any?) {
        let parent = PathCompletion.directoryURL(directory.deletingLastPathComponent())
        guard parent != directory else { return }
        navigate(to: parent)
    }

    @objc func goHome(_ sender: Any?) {
        navigate(to: FileManager.default.homeDirectoryForCurrentUser)
    }

    @objc func toggleHidden(_ sender: Any?) {
        showHidden.toggle()
        reload()
    }

    @objc func refresh(_ sender: Any?) {
        reload()
    }
}

// MARK: - Menu state

extension BrowserViewController: NSMenuItemValidation {
    /// Carries the checkmark on "Show Hidden Files". NSViewController does not
    /// validate menu items on its own, the protocol has to be asked for.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleHidden(_:)) {
            menuItem.state = showHidden ? .on : .off
        }
        return true
    }
}

// MARK: - Table data

extension BrowserViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let tableColumn, row < entries.count else { return nil }
        let entry = entries[row]

        switch tableColumn.identifier.rawValue {
        case "name":
            return nameCell(for: entry, in: tableView)
        case "size":
            let text = entry.isDirectory ? "--" : entry.size.map(Self.sizeFormatter.string) ?? ""
            return textCell(text, in: tableView, aligned: .right)
        case "modified":
            let text = entry.modified.map(Self.dateFormatter.string) ?? ""
            return textCell(text, in: tableView, aligned: .left)
        default:
            return nil
        }
    }

    private func nameCell(for entry: Entry, in tableView: NSTableView) -> NSView {
        let id = NSUserInterfaceItemIdentifier("nameCell")
        let cell =
            tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
            ?? Self.makeNameCell(id: id)

        cell.imageView?.image = NSWorkspace.shared.icon(forFile: entry.url.path)
        cell.textField?.stringValue = entry.name
        return cell
    }

    private static func makeNameCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle

        cell.addSubview(icon)
        cell.addSubview(label)
        cell.imageView = icon
        cell.textField = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func textCell(
        _ text: String,
        in tableView: NSTableView,
        aligned alignment: NSTextAlignment
    ) -> NSView {
        let id = NSUserInterfaceItemIdentifier("textCell.\(alignment.rawValue)")
        let cell =
            tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
            ?? Self.makeTextCell(id: id, alignment: alignment)

        cell.textField?.stringValue = text
        return cell
    }

    private static func makeTextCell(
        id: NSUserInterfaceItemIdentifier,
        alignment: NSTextAlignment
    ) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = alignment
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 11)

        cell.addSubview(label)
        cell.textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
