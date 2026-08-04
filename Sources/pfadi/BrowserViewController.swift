import AppKit
import PfadiCore
import Quartz

/// One window: a path field on top, a file list below, a count at the bottom.
final class BrowserViewController: NSViewController {
    private let preferences: Preferences
    private let favourites: Favourites

    /// Where this window is looking, for whoever needs to know: the sidebar,
    /// and the menu item that puts it in the sidebar.
    var currentDirectory: URL { directory }

    /// Told when moving somewhere changes what the arrows can do.
    var onHistoryChanged: ((_ canGoBack: Bool, _ canGoForward: Bool) -> Void)?

    /// Asked to open a folder in a tab of the same window.
    var onNewTab: ((URL) -> Void)?

    /// Told when the favourites change, so the sidebar can redraw.
    var onFavouritesChanged: (() -> Void)?

    private var directory: URL
    /// Everything in the folder, and the part of it currently on screen. The
    /// filter narrows the second without re-reading the first.
    private var allEntries: [Entry] = []
    private var entries: [Entry] = []
    private var filter = ""
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

    private var history = NavigationHistory()
    private let infoPanel = InfoPanel()
    private let transfers = TransferController()
    private let openWithMenu = NSMenu(title: "Open With")

    /// The row being renamed, and a folder that was just created and should be
    /// renamed as soon as the watcher shows it.
    private var renaming: URL?
    private var pendingRename: URL?

    private let listingQueue = DispatchQueue(
        label: "io.github.sapn95.pfadi.listing", qos: .userInitiated)

    private let pathField = PathField()
    private let searchField = NSSearchField()
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

    init(
        directory: URL,
        preferences: Preferences = Preferences(),
        favourites: Favourites? = nil
    ) {
        self.directory = PathCompletion.directoryURL(directory)
        self.preferences = preferences
        self.favourites = favourites ?? Favourites(preferences: preferences)
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
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Filter"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))

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
        view.addSubview(searchField)
        view.addSubview(scrollView)
        view.addSubview(statusLabel)
        view.addSubview(transfers.view)

        NSLayoutConstraint.activate([
            // The safe area, not the view: the window is fullSizeContentView so
            // that the sidebar's translucency can reach the top, which means
            // the content pane starts underneath the title bar.
            pathField.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            pathField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            pathField.trailingAnchor.constraint(
                equalTo: searchField.leadingAnchor, constant: -8),

            searchField.centerYAnchor.constraint(equalTo: pathField.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            searchField.widthAnchor.constraint(equalToConstant: 170),

            scrollView.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),

            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: transfers.view.leadingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),

            transfers.view.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -14),
            transfers.view.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
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

        tableView.menu = makeContextMenu()
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

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

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let openWith = menu.addItem(withTitle: "Open With", action: nil, keyEquivalent: "")
        openWith.submenu = openWithMenu

        menu.addItem(.separator())
        for (title, action) in [
            ("Open in New Tab", #selector(openInNewTab(_:))),
            ("Add to Favourites", #selector(toggleFavourite(_:))),
            ("Get Info", #selector(showInfo(_:))),
            ("Copy", #selector(copy(_:))),
            ("Paste", #selector(paste(_:))),
            ("Move Item Here", #selector(pasteAsMove(_:))),
            ("Copy Path", #selector(copyPath(_:))),
            ("Reveal in Finder", #selector(revealInFinder(_:))),
        ] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Rename", action: #selector(renameSelection(_:)), keyEquivalent: "")
            .target = self
        menu.addItem(
            withTitle: "Move to Trash", action: #selector(moveToTrash(_:)), keyEquivalent: ""
        ).target = self
        return menu
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
    private func enter(_ url: URL, recordingHistory: Bool = true) {
        // The filter described the folder being left. Carrying it into the next
        // one shows an empty list and no explanation.
        filter = ""
        searchField.stringValue = ""
        tableView.resetTypeAhead()
        if recordingHistory {
            history.visit(url)
        }
        directory = url
        reload(keepingSelection: false)
        preferences.lastDirectory = url.path
        favourites.remember(url)
        onFavouritesChanged?()

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
        onHistoryChanged?(history.canGoBack, history.canGoForward)
        pathField.stringValue = directory.path
        // Truncation hides the start, and the start is what you want when you
        // are checking which of two similar folders this is.
        pathField.toolTip = directory.path
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
            allEntries = listed
        case .failure(let error):
            // An unreadable directory is a normal event, not a crash: think
            // /Library/Caches, or anything behind a TCC prompt not yet granted.
            allEntries = []
            failure = "cannot read \(directory.path): \(error.localizedDescription)"
        }

        entries = Self.filtered(allEntries, by: filter)
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

        if let pending = pendingRename, let row = entries.firstIndex(where: { $0.url == pending }) {
            pendingRename = nil
            select(row: row)
            beginRename(row: row)
        }
    }

    private func statusText() -> String {
        if !filter.isEmpty {
            return "\(entries.count) of \(allEntries.count) match \u{201C}\(filter)\u{201D}"
        }
        guard !entries.isEmpty else { return "empty folder" }
        let folders = entries.filter(\.isDirectory).count
        var text = "\(entries.count) items, \(folders) folders"

        // Only in a cloud folder, and only when some of it is not here. In an
        // ordinary folder this line would be noise.
        let placeholders = entries.filter { $0.cloud.isCloud && !$0.cloud.isDownloaded }.count
        if placeholders > 0 {
            text += ", \(placeholders) online only"
        }
        return text + (showHidden ? ", hidden shown" : "")
    }

    /// Substring rather than prefix, and blind to case and accents. Looking for
    /// `config` should find `.eslintrc.config.js`, which a prefix match misses.
    private static func filtered(_ entries: [Entry], by text: String) -> [Entry] {
        guard !text.isEmpty else { return entries }
        return entries.filter {
            $0.name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    @objc func focusSearch(_ sender: Any?) {
        view.window?.makeFirstResponder(searchField)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        filter = sender.stringValue.trimmingCharacters(in: .whitespaces)
        entries = Self.filtered(allEntries, by: filter)
        tableView.reloadData()
        if !entries.isEmpty { select(row: 0) }
        statusLabel.stringValue = statusText()
    }

    private func select(row: Int) {
        guard entries.indices.contains(row) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func beginRename(row: Int) {
        guard entries.indices.contains(row) else { return }
        renaming = entries[row].url
        // The row's cell may already exist, made when renaming was nil and so
        // not editable. editColumn on a field that refuses to edit does
        // nothing at all and looks like the command was ignored.
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integer: 0))
        tableView.editColumn(0, row: row, with: nil, select: true)
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

    /// ⌘↓ on a folder, and the context menu. Opening in a tab keeps where you
    /// were, which is the entire point of having tabs.
    @objc func openInNewTab(_ sender: Any?) {
        guard let entry = selectedEntry(), entry.isDirectory else {
            NSSound.beep()
            return
        }
        onNewTab?(entry.url)
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
        // typedText, not stringValue: while the field is being edited the cell
        // can be a step behind what is on screen, and going somewhere other
        // than the path the person is looking at is the worst kind of wrong.
        let typed = pathField.typedText
        pathField.endCompletion()

        // A share is an address too, so it goes in the address bar rather than
        // behind a separate dialog with its own history.
        if let share = NetworkShare.url(from: typed) {
            connect(to: share)
            return
        }

        switch PathCompletion.resolve(typed, relativeTo: directory) {
        case .directory(let url):
            navigate(to: url)
        case .file(let url):
            NSWorkspace.shared.open(url)
            pathField.stringValue = directory.path
            view.window?.makeFirstResponder(tableView)
        case nil:
            NSSound.beep()
        }
    }

    func connect(to share: URL) {
        statusLabel.stringValue = "connecting to \(share.host ?? share.absoluteString)…"

        ShareMounter.mount(share) { [weak self] result in
            guard let self else { return }
            switch result {
            case .alreadyMounted(let url):
                statusLabel.stringValue = "already mounted"
                favourites.rememberServer(share)
                onFavouritesChanged?()
                navigate(to: url)
            case .mounted(let url):
                favourites.rememberServer(share)
                onFavouritesChanged?()
                navigate(to: url)
            case .needsCredentials:
                // The system already has a connect sheet with keychain and
                // guest handling in it. A second one would be worse.
                statusLabel.stringValue = "asking the system for credentials"
                ShareMounter.askSystemToConnect(share)
            case .failed(let reason):
                NSSound.beep()
                statusLabel.stringValue = reason
                pathField.stringValue = directory.path
            }
        }
    }

    /// ⌘K, which is the key everyone already presses for this.
    @objc func connectToServer(_ sender: Any?) {
        view.window?.makeFirstResponder(pathField)
        pathField.stringValue = "smb://"
        pathField.currentEditor()?.selectedRange = NSRange(location: 6, length: 0)
        statusLabel.stringValue = "type a share address, for example smb://server/share"
    }

    // MARK: - Menu actions

    @objc func focusPathField(_ sender: Any?) {
        view.window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
    }

    @objc func goBack(_ sender: Any?) {
        guard let url = history.back() else {
            NSSound.beep()
            return
        }
        // recordingHistory: false, or stepping back would itself be a visit
        // and you could never leave the last two folders.
        enter(url, recordingHistory: false)
        view.window?.makeFirstResponder(tableView)
    }

    @objc func goForward(_ sender: Any?) {
        guard let url = history.forward() else {
            NSSound.beep()
            return
        }
        enter(url, recordingHistory: false)
        view.window?.makeFirstResponder(tableView)
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

    // MARK: - Quick Look control
    //
    // In the class body rather than the extension below: these override
    // NSResponder, and an override belongs where the compiler can see the
    // superclass rather than in an extension where it works by @objc accident.

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    /// What ⌘D acts on: the selected folder, or the one on screen when the
    /// selection is a file or there is none. Right-clicking a folder and being
    /// offered the folder you are already in would be no use at all.
    private func favouriteTarget() -> URL {
        if let entry = selectedEntry(), entry.isDirectory { return entry.url }
        return directory
    }

    /// ⌘D, the same key Finder uses for the same thing.
    @objc func toggleFavourite(_ sender: Any?) {
        let target = favouriteTarget()
        let added = favourites.add(target)
        if !added {
            favourites.remove(target)
        }
        onFavouritesChanged?()
        statusLabel.stringValue =
            added
            ? "added \(target.lastPathComponent) to favourites"
            : "removed \(target.lastPathComponent) from favourites"
    }

    @objc func showInfo(_ sender: Any?) {
        infoPanel.show(actionTarget(), relativeTo: view.window)
    }

    @objc private func openWithApplication(_ sender: NSMenuItem) {
        guard let application = sender.representedObject as? URL, let entry = selectedEntry()
        else { return }
        OpenWith.open(entry.url, with: application)
    }

    @objc private func setDefaultApplication(_ sender: NSMenuItem) {
        guard let application = sender.representedObject as? URL, let entry = selectedEntry()
        else { return }
        OpenWith.setDefault(application, forKindOf: entry.url) { [weak self] message in
            self?.statusLabel.stringValue = message
        }
    }

    @objc private func openWithOther(_ sender: Any?) {
        guard let entry = selectedEntry() else { return }
        OpenWith.chooseApplication(for: entry.url, in: view.window) { application in
            OpenWith.open(entry.url, with: application)
        }
    }

    /// Built fresh every time it opens: which applications can open a file
    /// depends on the file, and on what has been installed since last time.
    private func rebuildOpenWithMenu(_ menu: NSMenu, for entry: Entry) {
        menu.removeAllItems()

        for candidate in OpenWith.candidates(for: entry.url) {
            let item = menu.addItem(
                withTitle: candidate.isDefault ? "\(candidate.name) (default)" : candidate.name,
                action: #selector(openWithApplication(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = candidate.url
            item.image = NSWorkspace.shared.icon(forFile: candidate.url.path)
            item.image?.size = NSSize(width: 16, height: 16)

            // Holding option turns the list into "and from now on". The system
            // sets a default per kind, never per file, so the title says kind.
            let always = menu.addItem(
                withTitle: "Always open every file of this kind with \(candidate.name)",
                action: #selector(setDefaultApplication(_:)),
                keyEquivalent: ""
            )
            always.target = self
            always.representedObject = candidate.url
            always.isAlternate = true
            always.keyEquivalentModifierMask = [.option]
        }

        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        let other = menu.addItem(
            withTitle: "Other…", action: #selector(openWithOther(_:)), keyEquivalent: "")
        other.target = self
    }

    // MARK: - Copy and paste

    /// Deliberately the standard `copy:` selector. When the path field has
    /// focus its field editor answers first and copies the text; only when the
    /// list has focus does this run and copy the file.
    @objc func copy(_ sender: Any?) {
        guard let entry = selectedEntry() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // File URLs, so this works with Finder and everything else that deals
        // in files rather than only within this application.
        pasteboard.writeObjects([entry.url as NSURL])
        statusLabel.stringValue = "copied \(entry.name)"
    }

    @objc func paste(_ sender: Any?) {
        transfer(kind: .copy)
    }

    @objc func pasteAsMove(_ sender: Any?) {
        transfer(kind: .move)
    }

    /// File URLs on the clipboard, from this application or any other.
    private func pasteboardURLs() -> [URL] {
        NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
    }

    /// Files dropped somewhere that is not the list: the sidebar, for now.
    /// Always a copy, because a drop onto a place in a list of places is not a
    /// gesture anybody makes meaning "and take it out of where it was".
    func transfer(_ sources: [URL], into destination: URL) {
        guard !transfers.isRunning else {
            statusLabel.stringValue = "one transfer at a time, for now"
            return
        }
        if let refusal = Transfer.check(moving: sources, into: destination, kind: .copy) {
            NSSound.beep()
            statusLabel.stringValue = refusal.message
            return
        }
        let plan = Transfer.plan(sources, into: destination, kind: .copy)
        transfers.start(plan, in: view.window) { [weak self] outcome in
            self?.finished(outcome, kind: .copy)
        }
    }

    private func transfer(kind: Transfer.Kind) {
        guard !transfers.isRunning else {
            statusLabel.stringValue = "one transfer at a time, for now"
            return
        }

        let sources = pasteboardURLs()
        guard !sources.isEmpty else {
            statusLabel.stringValue = "nothing on the clipboard to paste"
            return
        }

        if let refusal = Transfer.check(moving: sources, into: directory, kind: kind) {
            NSSound.beep()
            statusLabel.stringValue = refusal.message
            return
        }

        let plan = Transfer.plan(sources, into: directory, kind: kind)
        transfers.start(plan, in: view.window) { [weak self] outcome in
            self?.finished(outcome, kind: kind)
        }
    }

    private func finished(_ outcome: TransferRunner.Outcome, kind: Transfer.Kind) {
        registerUndo(kind == .copy ? "Copy" : "Move") { controller in
            let manager = FileManager.default

            switch kind {
            case .copy:
                // Backwards: the deepest thing was created last, and a folder
                // cannot go to the trash while its contents are still there.
                for url in outcome.created.reversed() {
                    _ = try? FileOperations.trash(url)
                }

            case .move:
                // Order matters and used to be wrong. Trashing the
                // destinations first and then moving them back out of the
                // trash fails every time, which turned undoing a move into
                // trashing everything that was moved.
                //
                // Put the folders back first, so there is somewhere to move
                // into; then the files; then take away the folders that were
                // made at the far end.
                for folder in outcome.emptiedSources.reversed() {
                    try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
                }
                for move in outcome.moved.reversed() {
                    try? manager.moveItem(at: move.to, to: move.from)
                }
                for url in outcome.created.reversed()
                where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    _ = try? FileOperations.trash(url)
                }
            }

            for displaced in outcome.displaced {
                try? manager.moveItem(at: displaced.inTrash, to: displaced.original)
            }
            controller.reload(keepingSelection: true)
        }

        var parts: [String] = []
        parts.append(outcome.cancelled ? "stopped" : (kind == .copy ? "copied" : "moved"))
        parts.append("\(outcome.created.count) items")
        if outcome.skipped > 0 { parts.append("\(outcome.skipped) skipped") }
        if !outcome.displaced.isEmpty {
            parts.append("\(outcome.displaced.count) replaced, the old ones are in the trash")
        }
        if !outcome.failed.isEmpty {
            NSSound.beep()
            parts.append("\(outcome.failed.count) failed: \(outcome.failed[0].1)")
        }
        statusLabel.stringValue = parts.joined(separator: ", ")
        reload(keepingSelection: true)
    }

    // MARK: - Writing to disk

    @objc func newFolder(_ sender: Any?) {
        let name = FileOperations.availableName("untitled folder", in: directory)
        do {
            let created = try FileOperations.createFolder(named: name, in: directory)
            registerUndo("New Folder") { controller in
                controller.attempt("undo the new folder") {
                    _ = try FileOperations.trash(created)
                }
                controller.registerUndo("New Folder") { controller in
                    controller.attempt("redo the new folder") {
                        try FileOperations.createFolder(named: name, in: controller.directory)
                    }
                }
            }
            statusLabel.stringValue = "created \(name)"
            // Normally the watcher brings the row in. On a folder it could not
            // attach to, nothing would ever arrive and the rename never starts.
            reload(keepingSelection: true)
            // The listing is watched, so the row will arrive on its own. Wait
            // for it, then put the cursor straight into its name: nobody wants
            // a folder called "untitled folder".
            pendingRename = created
        } catch {
            report(error, doing: "create a folder")
        }
    }

    @objc func renameSelection(_ sender: Any?) {
        guard let entry = selectedEntry(), let row = entries.firstIndex(of: entry) else { return }
        beginRename(row: row)
    }

    @objc func moveToTrash(_ sender: Any?) {
        guard let entry = selectedEntry() else { return }
        do {
            let trashed = try FileOperations.trash(entry.url)
            if let trashed {
                registerUndo("Move to Trash") { controller in
                    controller.attempt("put \(entry.name) back") {
                        try FileManager.default.moveItem(at: trashed, to: entry.url)
                    }
                    controller.registerUndo("Move to Trash") { controller in
                        controller.attempt("move \(entry.name) to the trash again") {
                            _ = try FileOperations.trash(entry.url)
                        }
                    }
                }
            }
            statusLabel.stringValue = "moved \(entry.name) to the trash"
        } catch {
            report(error, doing: "move \(entry.name) to the trash")
        }
    }

    /// Undo is worth the small amount of bookkeeping precisely because these
    /// are the first operations that change anything: ⌘Z should work from the
    /// first version that can lose you something.
    /// Runs something that touches the disk and says so when it fails.
    ///
    /// Undo used to swallow its errors. An undo that silently does nothing is
    /// worse than one that refuses, because the person believes it worked.
    fileprivate func attempt(_ what: String, _ work: () throws -> Void) {
        do {
            try work()
        } catch {
            report(error, doing: what)
        }
        reload(keepingSelection: true)
    }

    fileprivate func registerUndo(
        _ name: String, _ undo: @escaping (BrowserViewController) -> Void
    ) {
        guard let manager = undoManager else { return }
        manager.setActionName(name)
        manager.registerUndo(withTarget: self) { controller in
            undo(controller)
        }
    }

    private func report(_ error: any Error, doing what: String) {
        NSSound.beep()
        statusLabel.stringValue = "could not \(what): \(error.localizedDescription)"
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
        if menuItem.action == #selector(goBack(_:)) { return history.canGoBack }
        if menuItem.action == #selector(goForward(_:)) { return history.canGoForward }

        // Greyed out rather than beeping. A paste with an empty clipboard and a
        // rename with nothing selected are both questions with no answer.
        if menuItem.action == #selector(paste(_:))
            || menuItem.action == #selector(pasteAsMove(_:))
        {
            return !transfers.isRunning && !pasteboardURLs().isEmpty
        }
        if menuItem.action == #selector(openInNewTab(_:)) {
            return selectedEntry()?.isDirectory == true
        }
        if menuItem.action == #selector(copy(_:))
            || menuItem.action == #selector(renameSelection(_:))
            || menuItem.action == #selector(moveToTrash(_:))
        {
            return selectedEntry() != nil
        }
        if menuItem.action == #selector(toggleFavourite(_:)) {
            let target = favouriteTarget()
            let name = target.path == directory.path ? "This Folder" : target.lastPathComponent
            menuItem.title =
                favourites.contains(target)
                ? "Remove \(name) from Favourites"
                : "Add \(name) to Favourites"
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
        infoPanel.update(selectedEntry()?.url ?? directory)

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
            var text = entry.isDirectory ? "--" : entry.size.map(Self.sizeFormatter.string) ?? ""
            // A placeholder has a size and no bytes. Saying so here is the
            // difference between copying a folder and downloading it.
            if entry.cloud.isCloud, !entry.cloud.isDownloaded {
                text = "\u{2601} \(text)"
            }
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
        cell.textField?.delegate = self
        cell.textField?.isEditable = (renaming == entry.url)
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
        // Not editable until a rename starts, but it has to be a field rather
        // than a label or there is nothing to type into when one does.
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.focusRingType = .none

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

// MARK: - Renaming

extension BrowserViewController: NSTextFieldDelegate {
    /// The rename is committed when the field gives up focus, which covers
    /// return, tab and clicking somewhere else. Escape never gets here: AppKit
    /// puts the old text back and ends editing without telling the delegate a
    /// new value.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field !== pathField else { return }
        defer {
            field.isEditable = false
            renaming = nil
        }

        guard let original = renaming else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != original.lastPathComponent else { return }

        if let problem = FileOperations.problem(with: name) {
            field.stringValue = original.lastPathComponent
            report(RenameRefused(problem: problem), doing: "rename \(original.lastPathComponent)")
            return
        }

        do {
            let renamed = try FileOperations.rename(original, to: name)
            registerUndo("Rename") { controller in
                controller.attempt("undo the rename") {
                    _ = try FileOperations.rename(renamed, to: original.lastPathComponent)
                }
                controller.registerUndo("Rename") { controller in
                    controller.attempt("redo the rename") {
                        _ = try FileOperations.rename(original, to: name)
                    }
                }
            }
            statusLabel.stringValue = "renamed to \(name)"
        } catch {
            // Put the old name back on screen: the row still says the new one,
            // and a list that disagrees with the disk is worse than an error.
            field.stringValue = original.lastPathComponent
            report(error, doing: "rename \(original.lastPathComponent)")
        }
    }
}

private struct RenameRefused: LocalizedError {
    let problem: FileOperations.NameProblem
    var errorDescription: String? { problem.message }
}

// MARK: - Context menu

extension BrowserViewController: NSMenuDelegate {
    /// A right-click does not move the selection, so the menu has to act on the
    /// row that was clicked. Selecting it first is the least surprising way to
    /// make every item in the menu agree about which file it means.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let clicked = tableView.clickedRow
        if entries.indices.contains(clicked), clicked != tableView.selectedRow {
            select(row: clicked)
        }
        guard let entry = selectedEntry() else { return }
        rebuildOpenWithMenu(openWithMenu, for: entry)
    }
}

// MARK: - Drag and drop

extension BrowserViewController {
    /// Dragging out. A row is its file URL, so this works into any application
    /// that takes files, not only back into this one.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
        -> (any NSPasteboardWriting)?
    {
        entries.indices.contains(row) ? entries[row].url as NSURL : nil
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation operation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard !transfers.isRunning else { return [] }
        let sources = draggedURLs(info)
        guard !sources.isEmpty else { return [] }

        // Dropping between rows means "into the folder on screen"; dropping on
        // a row means that row, but only when it is a folder.
        let destination: URL
        if operation == .on, entries.indices.contains(row), entries[row].isDirectory {
            destination = entries[row].url
        } else {
            destination = directory
            tableView.setDropRow(-1, dropOperation: .on)
        }

        let transferKind = kind(for: info, into: destination)
        guard Transfer.check(moving: sources, into: destination, kind: transferKind) == nil
        else { return [] }
        return transferKind == .move ? .move : .copy
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation operation: NSTableView.DropOperation
    ) -> Bool {
        let sources = draggedURLs(info)
        guard !sources.isEmpty else { return false }

        let destination: URL
        if operation == .on, entries.indices.contains(row), entries[row].isDirectory {
            destination = entries[row].url
        } else {
            destination = directory
        }

        let transferKind = kind(for: info, into: destination)
        if let refusal = Transfer.check(moving: sources, into: destination, kind: transferKind) {
            NSSound.beep()
            statusLabel.stringValue = refusal.message
            return false
        }

        let plan = Transfer.plan(sources, into: destination, kind: transferKind)
        transfers.start(plan, in: view.window) { [weak self] outcome in
            self?.finished(outcome, kind: transferKind)
        }
        return true
    }

    private func draggedURLs(_ info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
    }

    /// Finder's rule, because muscle memory is the only rule that matters here:
    /// within a volume a drag moves, across volumes it copies, option forces a
    /// copy and command forces a move.
    private func kind(for info: any NSDraggingInfo, into destination: URL) -> Transfer.Kind {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.option) { return .copy }
        if modifiers.contains(.command) { return .move }

        // Against the folder being dropped into, not the one on screen. Those
        // differ whenever the drop lands on a folder row, and a folder row can
        // be a mount point on another volume.
        guard let source = draggedURLs(info).first else { return .copy }
        return sameVolume(source, destination) ? .move : .copy
    }

    private func sameVolume(_ left: URL, _ right: URL) -> Bool {
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        let a = try? left.resourceValues(forKeys: key).volumeIdentifier
        let b = try? right.resourceValues(forKeys: key).volumeIdentifier
        guard let a, let b else { return false }
        return a.isEqual(b)
    }
}
