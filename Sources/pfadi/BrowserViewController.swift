import AppKit
import PfadiCore
import Quartz

/// One window: a path field on top, a file list below, a count at the bottom.
final class BrowserViewController: NSViewController {
    private let preferences: Preferences

    private var directory: URL
    private var entries: [Entry] = []
    private var showHidden: Bool {
        didSet { preferences.showHidden = showHidden }
    }
    private var order: ListingOrder {
        didSet { preferences.sortOrder = order }
    }
    private var watcher: DirectoryWatcher?

    /// Counts reload requests so a slow listing for a folder we have since
    /// left can be recognised and dropped.
    private var generation = 0

    private let listingQueue = DispatchQueue(
        label: "io.github.sapn95.pfadi.listing", qos: .userInitiated)

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

    init(directory: URL, preferences: Preferences = Preferences()) {
        self.directory = PathCompletion.directoryURL(directory)
        self.preferences = preferences
        // A choice made once should still be true next launch, so this is read
        // back rather than defaulted.
        self.showHidden = preferences.showHidden
        self.order = preferences.sortOrder
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
        pathField.onCompletionChanged = { [weak self] progress in
            guard let self else { return }
            statusLabel.stringValue = progress ?? statusText()
        }

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
        tableView.onTypeAhead = { [weak self] prefix in self?.typeAhead(prefix) }
        tableView.onSpace = { [weak self] in self?.toggleQuickLook() }

        addColumn(id: "name", title: "Name", width: 420)
        addColumn(id: "size", title: "Size", width: 90)
        addColumn(id: "modified", title: "Modified", width: 160)

        // Column widths are the other thing a person sets once and expects to
        // find again, and AppKit persists them itself once the table has a
        // name. It has to come after the columns exist: the saved widths are
        // applied to the columns present at the moment the name is set, so
        // doing this first silently restores nothing at all.
        tableView.autosaveName = "io.github.sapn95.pfadi.files"
        tableView.autosaveTableColumns = true

        // Show the order that was restored, without asking for a reload: the
        // first listing has not happened yet.
        tableView.sortDescriptors = [
            NSSortDescriptor(key: order.key.rawValue, ascending: order.ascending)
        ]
    }

    private func addColumn(id: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        // The prototype is what makes the header clickable and draws the
        // arrow. AppKit only reports the change; the sorting is ours.
        column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
        tableView.addTableColumn(column)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        enter(directory)
        view.window?.makeFirstResponder(tableView)
    }

    // MARK: - Navigation

    func navigate(to url: URL) {
        enter(PathCompletion.directoryURL(url))
        view.window?.makeFirstResponder(tableView)
    }

    /// Moves to a folder: list it, watch it, remember it, select the top row.
    private func enter(_ url: URL) {
        directory = url
        reload(keepingSelection: false)
        preferences.lastDirectory = url.path

        watcher?.stop()
        watcher = DirectoryWatcher(url: url) { [weak self] in
            // Something changed out there. Keep the cursor where the person
            // left it, or a build finishing would yank them back to the top.
            self?.reload(keepingSelection: true)
        }
        watcher?.start()
    }

    /// Lists the folder on a worker and applies the result on the main thread.
    ///
    /// Enumerating a directory is a synchronous filesystem call. On a network
    /// mount or a folder with tens of thousands of entries it takes long enough
    /// to freeze every menu, keystroke and scroll in the application, and the
    /// watcher makes it happen without anybody asking.
    private func reload(keepingSelection: Bool) {
        let previous = keepingSelection ? selectedEntry()?.name : nil

        // The path field and the title describe where we are going, so they
        // update immediately rather than when the listing arrives.
        pathField.stringValue = directory.path
        pathField.showHidden = showHidden
        pathField.currentDirectory = directory
        view.window?.title = directory.lastPathComponent.isEmpty ? "/" : directory.lastPathComponent

        generation &+= 1
        let generation = self.generation
        let directory = self.directory
        let showHidden = self.showHidden
        let order = self.order

        listingQueue.async { [weak self] in
            let result = Result {
                try DirectoryListing.read(directory, showHidden: showHidden, order: order)
            }
            DispatchQueue.main.async {
                // A newer navigation has already been asked for, so this answer
                // is about a folder nobody is looking at any more.
                guard let self, generation == self.generation else { return }
                self.apply(result, directory: directory, previousSelection: previous)
            }
        }
    }

    private func apply(
        _ result: Result<[Entry], any Error>,
        directory: URL,
        previousSelection: String?
    ) {
        var failure: String?
        switch result {
        case .success(let listed):
            entries = listed
        case .failure(let error):
            // An unreadable directory is a normal event, not a crash: think
            // /Library/Caches, or anything behind a TCC prompt not yet granted.
            entries = []
            failure = "cannot read \(directory.path): \(error.localizedDescription)"
        }

        tableView.reloadData()

        guard !entries.isEmpty else {
            statusLabel.stringValue = failure ?? "empty folder"
            return
        }

        // The remembered row may have been renamed or deleted by whatever
        // triggered this reload, so falling back to the top is normal.
        let row =
            previousSelection.flatMap { name in entries.firstIndex { $0.name == name } } ?? 0
        select(row: row)

        statusLabel.stringValue = statusText()
    }

    private func statusText() -> String {
        guard !entries.isEmpty else { return "empty folder" }
        let folders = entries.filter(\.isDirectory).count
        return "\(entries.count) items, \(folders) folders" + (showHidden ? ", hidden shown" : "")
    }

    private func select(row: Int) {
        guard entries.indices.contains(row) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func selectedEntry() -> Entry? {
        let row = tableView.selectedRow
        return entries.indices.contains(row) ? entries[row] : nil
    }

    /// What the actions work on: the selected row, or the folder itself when
    /// nothing is selected. Copying "the path" with an empty list should still
    /// give you a path.
    private func actionTarget() -> URL {
        selectedEntry()?.url ?? directory
    }

    @objc private func openSelection() {
        guard let entry = selectedEntry() else { return }
        if entry.isDirectory {
            navigate(to: entry.url)
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }

    private func typeAhead(_ prefix: String) {
        let row = TypeAhead.index(
            matching: prefix,
            in: entries.map(\.name),
            current: tableView.selectedRow >= 0 ? tableView.selectedRow : nil
        )
        guard let row else {
            NSSound.beep()
            return
        }
        select(row: row)
    }

    @objc private func pathFieldCommitted(_ sender: NSTextField) {
        pathField.endCompletion()
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
        reload(keepingSelection: true)
    }

    @objc func refresh(_ sender: Any?) {
        reload(keepingSelection: true)
    }

    @objc func copyPath(_ sender: Any?) {
        let target = actionTarget()
        Actions.copyPath(target)
        statusLabel.stringValue = "copied \(target.path)"
    }

    @objc func revealInFinder(_ sender: Any?) {
        Actions.revealInFinder(actionTarget())
    }

    @objc func openTerminalHere(_ sender: Any?) {
        // A shell opens in a folder, never on a file: use the folder holding
        // the selection when something is selected.
        let target = selectedEntry().map { $0.isDirectory ? $0.url : directory } ?? directory
        Actions.openTerminal(at: target)
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

    /// A header was clicked. AppKit has already flipped the arrow, so all that
    /// is left is to agree with it and re-read the folder.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
            let panel = QLPreviewPanel.shared(), panel.isVisible
        else { return }
        panel.reloadData()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        guard
            let descriptor = tableView.sortDescriptors.first,
            let key = descriptor.key.flatMap(ListingOrder.Key.init(rawValue:))
        else { return }

        order = ListingOrder(key: key, ascending: descriptor.ascending)
        reload(keepingSelection: true)
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

// MARK: - Quick Look

extension BrowserViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// Space opens the preview, and space again closes it. Holding the panel
    /// open while walking the list with the arrow keys is the whole point, so
    /// the selection tells the panel to refresh rather than reopening it.
    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedEntry() == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        selectedEntry()?.url as (any QLPreviewItem)?
    }

    /// Send the panel's own key events back to the table, so the arrow keys
    /// still move the selection while the preview has focus.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        tableView.keyDown(with: event)
        return true
    }
}
