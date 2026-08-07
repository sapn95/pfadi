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
    /// The folder the current rows were read from.
    private var loadedDirectory: URL?

    private var history = NavigationHistory()
    private let infoPanel = InfoPanel()
    private let transfers = TransferController()
    private let openWithMenu = NSMenu(title: "Open With")
    /// Kept so the shared menu delegate can tell the header's menu from the
    /// list's, which want opposite things when they open.
    private var headerMenu: NSMenu?

    /// The row being renamed, and a folder that was just created and should be
    /// renamed as soon as the watcher shows it.
    private var renaming: URL?
    private var pendingRename: URL?

    /// A file somebody asked to be shown, and the folder it should turn up in.
    ///
    /// The folder is part of it because the listing arrives later: without it,
    /// a reveal asked for while another folder was still loading would select a
    /// same-named row in whichever listing landed first.
    private var pendingSelection: (folder: URL, name: String)?

    /// What the status line has been told to say, and until when.
    private var announcement: String?
    private var announcementUntil = Date.distantPast
    private static let announcementLifetime: TimeInterval = 8

    /// Folder sizes, measured only for the rows on screen.
    private let folderSizes = FolderSizeQueue()
    /// Whether a re-sort is already on its way, so measurements arriving in a
    /// burst schedule one between them rather than one each.
    private var resortScheduled = false

    /// Notification observers, removed on the way out. A block observer that is
    /// never removed keeps its closure, and with it this controller, alive for
    /// the life of the process.
    private var observers: [any NSObjectProtocol] = []

    private let listingQueue = DispatchQueue(
        label: "io.github.sapn95.pfadi.listing", qos: .userInitiated)

    /// How many times the whole table has been rebuilt, for the checks.
    ///
    /// A rebuild replaces the cell views, and a cell replaced under the pointer
    /// breaks a double click in progress. Counting them is how a check can tell
    /// "the list is up to date" from "the list was thrown away and made again".
    private(set) var reloadCount = 0

    private let pathBar = PathBar()
    /// Switches the path row between the clickable bar and the text field. A
    /// button, because a keystroke and a double click are both things you have
    /// to be told about and a visible control is not.
    private let pathToggle = NSButton()
    private let pathField = PathField()
    private let searchField = NSSearchField()
    private let tableView = FileTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    /// Where anything that did not happen gets said, because the status line
    /// is the wrong size and the wrong colour for it.
    private let banner = NoticeBanner()

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

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Where everything ended up, for the layout check.
    ///
    /// Named rather than returned as a list of views, so a failure says "the
    /// filter ends outside the view" instead of naming a class.
    struct LayoutReport {
        let bounds: NSRect
        let frames: [String: NSRect]
    }

    func pathComponents() -> [String] { pathBar.drawnComponents() }

    // What the checks need to see, kept together and named for what they mean
    // rather than for the views behind them.
    var rowCount: Int { entries.count }
    /// Which folder the rows on screen actually came from.
    ///
    /// Not the same as currentDirectory: that changes the moment you navigate,
    /// and the rows arrive later. A check that waits for "some rows" is
    /// satisfied by the folder it just left.
    var listedDirectory: URL? { loadedDirectory }
    var showsHiddenFiles: Bool { showHidden }
    var isFavourite: Bool { favourites.contains(favouriteTarget()) }
    /// The name of the first selected row, or nothing when there is no
    /// selection.
    var selectedName: String? { selectedEntry()?.name }
    /// Every selected name, for the checks.
    var selectedNames: [String] { selectedEntries().map(\.name) }
    var statusLine: String { statusLabel.stringValue }

    /// Selects a range the way ⇧↓ does, for the checks.
    ///
    /// Through the table's own selection rather than around it: what was
    /// broken was that the table refused to hold more than one row, and a
    /// check that kept its own list would have passed the whole time.
    func selectRange(_ rows: Range<Int>) {
        tableView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }

    /// Adds one row to the selection the way a ⌘-click does.
    func addToSelection(row: Int) {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: true)
    }

    /// Deselects everything, for the checks.
    ///
    /// With nothing selected the actions work on the folder on screen, which
    /// makes what they were asked for unambiguous.
    func clearSelection() {
        tableView.deselectAll(nil)
    }

    /// Double-clicks a row the way a mouse does, for the checks.
    ///
    /// A real event through the table's own `mouseDown`, not a call to the
    /// action behind it. What was broken was the path between the two, and a check
    /// that steps over it proves nothing.
    @discardableResult
    func doubleClickRow(_ row: Int) -> Bool {
        guard entries.indices.contains(row) else { return false }
        let rect = tableView.rect(ofRow: row)
        let point = NSPoint(x: rect.midX, y: rect.midY)
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: tableView.convert(point, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: tableView.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 2,
            pressure: 1)
        guard let event else { return false }
        tableView.mouseDown(with: event)
        return true
    }

    /// A reload of the kind the watcher asks for, for the checks.
    ///
    /// Not `refresh`, which also throws the measured folder sizes away on
    /// purpose. The watcher fires whenever anything in the folder is written
    /// and asks only for the listing to be read again.
    func reloadAsWatcherWould() {
        reload(keepingSelection: true)
    }

    /// The first folder in the listing, for the checks.
    var firstFolderName: String? { entries.first(where: \.isDirectory)?.name }

    /// Which row a name is on, for the checks.
    func rowIndex(of name: String) -> Int? {
        entries.firstIndex { $0.name == name }
    }

    /// The rows as they are ordered right now, for the checks.
    var listedNames: [String] { entries.map(\.name) }

    /// Clicks a column header, for the checks.
    ///
    /// The same thing AppKit does: take the column's prototype descriptor, flip
    /// it when that column is already the one being sorted by, and hand the
    /// result to the table. Setting `order` directly would prove the sort works
    /// while the header that has to reach it stays broken.
    @discardableResult
    func clickColumnHeader(_ identifier: String) -> Bool {
        let index = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(identifier))
        guard index >= 0 else { return false }
        let column = tableView.tableColumns[index]
        guard let prototype = column.sortDescriptorPrototype else { return false }

        let current = tableView.sortDescriptors.first
        let ascending =
            current?.key == prototype.key ? !(current?.ascending ?? true) : prototype.ascending
        tableView.sortDescriptors = [NSSortDescriptor(key: prototype.key, ascending: ascending)]
        return true
    }
    /// What has been measured for a folder in this listing, if anything.
    func measuredSize(of name: String) -> FolderSize.Measurement? {
        entries.first { $0.name == name }.flatMap { folderSizes.cached($0.url) }
    }

    func setFilter(_ text: String) {
        searchField.stringValue = text
        searchChanged(searchField)
    }

    /// Clicks a folder in the path bar, for the checks.
    @discardableResult
    func clickPathComponent(_ path: String, clicks: Int = 1) -> Bool {
        pathBar.clickComponent(path: path, clicks: clicks)
    }

    /// Whether a sibling menu is still waiting to open, for the checks.
    var isPathMenuPending: Bool { pathBar.isMenuPending }

    /// What a right-click on the column headers would actually open.
    ///
    /// Through `menu(for:)`, which is the method AppKit calls, rather than
    /// reading the property we set. Those are not the same question: a menu can
    /// be assigned to a view that never offers it.
    func headerMenuForRightClick() -> NSMenu? {
        (tableView.headerView as? ColumnHeaderView)?.menuForRightClick()
    }

    /// Turns a column on or off the way the header menu does, for the checks.
    @discardableResult
    func pickColumnFromHeaderMenu(_ column: ListingColumn) -> Bool {
        guard let menu = headerMenu,
            let item = menu.items.first(where: {
                $0.representedObject as? String == column.rawValue
            })
        else { return false }
        menuNeedsUpdate(menu)
        toggleColumn(item)
        return true
    }

    /// What the banner is saying, for the checks. Empty when it is not showing.
    var bannerMessage: String { banner.message }

    /// What a cell actually says, for the checks.
    func cellText(row: Int, column: ListingColumn) -> String {
        guard entries.indices.contains(row) else { return "" }
        return text(for: entries[row], in: column)
    }

    /// The columns on screen, in the order they are drawn, for the checks.
    var visibleColumns: [String] {
        tableView.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue }
    }

    /// Picks a column out of the header menu, for the checks.
    @discardableResult
    func clickHeaderMenuItem(_ identifier: String) -> Bool {
        guard let menu = headerMenu,
            let item = menu.items.first(where: { $0.representedObject as? String == identifier })
        else { return false }
        // Through the delegate first, so the state the menu would show is the
        // state being checked.
        menuNeedsUpdate(menu)
        guard item.isEnabled || identifier == "name" else { return false }
        toggleColumn(item)
        return true
    }

    func layoutReport() -> LayoutReport {
        view.layoutSubtreeIfNeeded()
        var frames: [String: NSRect] = [
            "path row": pathBar.isHidden ? pathField.frame : pathBar.frame,
            "path toggle": pathToggle.frame,
            "filter": searchField.frame,
            "status": statusLabel.frame,
        ]
        if let scrollView = tableView.enclosingScrollView {
            frames["list"] = scrollView.frame
        }
        return LayoutReport(bounds: view.bounds, frames: frames)
    }

    // MARK: - View

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 560))

        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.target = self
        pathField.action = #selector(pathFieldCommitted(_:))
        pathBar.translatesAutoresizingMaskIntoConstraints = false
        pathBar.onChoose = { [weak self] url in self?.navigate(to: url) }
        pathBar.onEdit = { [weak self] in self?.focusPathField(nil) }
        pathField.onEndEditing = { [weak self] in
            guard let self else { return }
            // Whatever half-typed path is in there described a place nobody
            // went to, so it goes back to saying where we actually are.
            pathField.stringValue = directory.path
            showPathField(false)
        }

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

        // Scrolling changes which folders are worth measuring. Asked for here
        // rather than on a timer: the answer is only ever needed for rows
        // somebody can see.
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in self?.measureVisibleFolders() })

        folderSizes.onMeasured = { [weak self] url, _ in
            guard let self else { return }
            redrawSize(of: url)
            resortLater()
        }

        pathToggle.translatesAutoresizingMaskIntoConstraints = false
        pathToggle.bezelStyle = .accessoryBar
        pathToggle.isBordered = false
        pathToggle.target = self
        pathToggle.action = #selector(togglePathEditing(_:))

        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.onVisibilityChanged = { [weak self] in self?.view.needsLayout = true }

        view.addSubview(banner)
        view.addSubview(pathToggle)
        view.addSubview(pathBar)
        view.addSubview(pathField)
        view.addSubview(searchField)
        view.addSubview(scrollView)
        view.addSubview(statusLabel)
        view.addSubview(transfers.view)

        NSLayoutConstraint.activate([
            // The safe area, not the view: the window is fullSizeContentView so
            // that the sidebar's translucency can reach the top, which means
            // the content pane starts underneath the title bar.
            pathBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            pathBar.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            // The bar fills the same slot as the field it swaps with. Its
            // folders and its arrow sit at the left of it and the empty part is
            // what takes a double click, so it needs the whole width rather
            // than only as much as the folders happen to want.
            pathBar.trailingAnchor.constraint(equalTo: pathField.trailingAnchor),
            pathBar.heightAnchor.constraint(equalTo: pathField.heightAnchor),

            pathField.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            pathField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            pathField.trailingAnchor.constraint(
                equalTo: pathToggle.leadingAnchor, constant: -4),

            pathToggle.centerYAnchor.constraint(equalTo: pathField.centerYAnchor),
            pathToggle.trailingAnchor.constraint(
                equalTo: searchField.leadingAnchor, constant: -8),
            pathToggle.widthAnchor.constraint(equalToConstant: 24),

            searchField.centerYAnchor.constraint(equalTo: pathField.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            searchField.widthAnchor.constraint(equalToConstant: 170),

            // A floor under the list. Without one the whole view's fitting
            // size is the path row plus the status line, AppKit sizes the
            // window to that, and the frame autosave then remembers a window
            // sixty points tall for every launch after.
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            // Low enough to fit inside the window's own minimum once the
            // sidebar has taken its share. A floor that cannot be met is a
            // constraint conflict, and AppKit resolves those by breaking
            // something and carrying on quietly.
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),

            // Between the path row and the list. Hidden it is zero high, so
            // the list keeps every point of the window when there is nothing
            // to say.
            banner.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 8),
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 8),
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
        // ⌘-click to add one, shift-click for a range, ⇧↑ and ⇧↓ to extend.
        // AppKit does all three itself once it is allowed to; what it cannot
        // do is make the actions below act on more than the first row, which
        // is the rest of the work.
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.onDoubleClick = { [weak self] row in
            guard let self else { return }
            // Double-clicking one of several selected rows opens all of them,
            // the way it does everywhere else. Only a click outside the
            // selection narrows it to the row under the pointer — which also
            // covers a reload having moved the selection between the clicks.
            if !tableView.selectedRowIndexes.contains(row) {
                select(row: row)
            }
            openSelection()
        }
        tableView.onReturn = { [weak self] in self?.openSelection() }
        tableView.onTypeAhead = { [weak self] prefix in self?.typeAhead(prefix) }
        tableView.onSpace = { [weak self] in self?.toggleQuickLook() }

        tableView.menu = makeContextMenu()
        tableView.registerForDraggedTypes([.fileURL])
        // Both masks. Only the external one was set, so dragging a row onto a
        // folder in the same window had no operation to offer and the drop was
        // refused before any of the code below ran.
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)

        // Every column exists; the ones nobody asked for are hidden. Added and
        // removed instead, they would lose their width every time and the
        // header could not be sorted by something that is not there.
        for column in ListingColumn.allCases {
            addColumn(column)
        }
        applyChosenColumns()

        // Right-click the headers for what else there is to show. A column you
        // cannot discover is a column nobody has. Through our own header view,
        // because NSTableHeaderView handles the right button itself and never
        // gets as far as putting a menu up.
        let header = makeHeaderMenu()
        headerMenu = header
        let headerView = ColumnHeaderView()
        headerView.menu = header
        tableView.headerView = headerView
        // Drag a header to move it. On by default in AppKit, set here because
        // it is a decision rather than an accident, and the autosave keeps the
        // order across a quit.
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true

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

    /// The menu behind a right-click on the column headers.
    ///
    /// Built once and updated when it opens, because which columns are on is a
    /// thing that changes and a menu built at launch would stop being true the
    /// first time one was switched.
    private func makeHeaderMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        for column in ListingColumn.allCases {
            let item = menu.addItem(
                withTitle: column.title,
                action: #selector(toggleColumn(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
        }
        menu.addItem(.separator())
        let hint = menu.addItem(
            withTitle: "Drag a header to reorder", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        return menu
    }

    @objc func toggleColumn(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
            let column = ListingColumn(rawValue: identifier)
        else { return }

        guard column.canBeHidden else {
            NSSound.beep()
            warn("the name column cannot be hidden")
            return
        }

        // Which columns, not what order: the order on screen is AppKit's,
        // kept by autosaveTableColumns along with the widths, and a second
        // opinion about it here would fight the header somebody just dragged.
        var chosen = preferences.columns
        let wanted = !chosen.contains(column)
        if wanted {
            chosen.append(column)
        } else {
            chosen.removeAll { $0 == column }
        }
        preferences.columns = chosen
        applyChosenColumns()

        // Sorting by a column that has just been taken away would leave the
        // list in an order with nothing on screen to explain it.
        if !wanted, order.key == column.sortKey {
            sortByName()
        }
        announce(wanted ? "showing \(column.title)" : "hiding \(column.title)")
        // Only when the new column needs something the listing did not read.
        // Switching one off, or on when its values are already in hand, is a
        // redraw rather than a trip to the disk.
        if wanted, !column.resourceKeys.isEmpty || column.needsFileStatus {
            reload(keepingSelection: true)
        } else {
            rebuildTable()
        }
    }

    /// Hides everything nobody asked for, shows everything they did.
    ///
    /// By identifier, so it does not care what order the headers are in. That
    /// order belongs to AppKit: `autosaveTableColumns` keeps it across a quit
    /// along with the widths, which is why the stored list is about visibility
    /// and nothing else.
    private func applyChosenColumns() {
        let chosen = Set(preferences.columns)
        for column in ListingColumn.allCases {
            let index = tableView.column(
                withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))
            guard index >= 0 else { continue }
            tableView.tableColumns[index].isHidden = !chosen.contains(column)
        }
    }

    private func sortByName() {
        order = ListingOrder(key: .name, ascending: true)
        tableView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
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
            ("Show in Finder", #selector(showInFinder(_:))),
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

    private func addColumn(_ listed: ListingColumn) {
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier(listed.rawValue))
        column.title = listed.title
        column.width = listed.width
        // The prototype is what makes the header clickable and draws the
        // arrow. AppKit only reports the change; the sorting is ours. A column
        // with no sort key gets no prototype, so its header does not pretend
        // to be clickable.
        column.sortDescriptorPrototype = listed.sortKey.map {
            NSSortDescriptor(key: $0.rawValue, ascending: true)
        }
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

    /// Shows a file in the folder that holds it, with its row selected.
    ///
    /// What "Reveal in Finder" in some other application ends up calling, once
    /// `pfadi-default apply` has pointed the system's file viewer here. Also
    /// `pfadi -R <path>`.
    func reveal(_ url: URL) {
        let parent = PathCompletion.directoryURL(url.deletingLastPathComponent())
        pendingSelection = (folder: parent, name: url.lastPathComponent)

        // Already looking at the right folder with its rows in place: select
        // now rather than re-reading a directory that has not changed.
        if loadedDirectory?.path == parent.path {
            applyPendingSelection()
            view.window?.makeFirstResponder(tableView)
            return
        }
        navigate(to: parent)
    }

    /// Selects the revealed row once its folder is on screen.
    private func applyPendingSelection() {
        guard let asked = pendingSelection, asked.folder.path == loadedDirectory?.path else {
            return
        }
        pendingSelection = nil

        guard let row = entries.firstIndex(where: { $0.name == asked.name }) else {
            // The folder is right and the file is not in it: deleted since,
            // or hidden by a filter that is not ours to clear.
            announce("\(asked.name) is not in this folder")
            NSSound.beep()
            return
        }
        select(row: row)
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
        // Whatever is being walked is for a folder nobody is looking at any
        // more. What has already been measured is kept, so going back is
        // instant.
        folderSizes.cancelPending()
        // Whatever was announced was about the folder being left.
        announcement = nil
        banner.hide()
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
        // Every selected name, not merely the first. The watcher fires
        // whenever anything in the folder is written, and collapsing a
        // five-row selection to one because a build wrote a log file is the
        // kind of thing that makes a list feel hostile.
        let previous = keepingSelection ? selectedEntries().map(\.name) : []

        // The path field and the title describe where we are going, so they
        // update immediately rather than when the listing arrives.
        onHistoryChanged?(history.canGoBack, history.canGoForward)
        pathField.stringValue = directory.path
        // Truncation hides the start, and the start is what you want when you
        // are checking which of two similar folders this is.
        pathField.toolTip = directory.path
        pathBar.directory = directory
        pathBar.showHidden = showHidden
        showPathField(false)
        pathField.showHidden = showHidden
        pathField.currentDirectory = directory
        view.window?.title = directory.lastPathComponent.isEmpty ? "/" : directory.lastPathComponent

        generation &+= 1
        let generation = self.generation
        let directory = self.directory
        let showHidden = self.showHidden
        let order = self.order
        // Only what is on screen is read off the disk: tags, owner and
        // permissions each cost something per entry, and a folder of forty
        // thousand files should not pay for a column nobody switched on.
        let columns = preferences.columns

        listingQueue.async { [weak self] in
            let result = Result {
                try DirectoryListing.read(
                    directory, showHidden: showHidden, order: order, columns: columns)
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
        previousSelection: [String]
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

        allEntries = resorted(allEntries)
        let updated = Self.filtered(allEntries, by: filter)
        let unchanged = updated == entries && loadedDirectory?.path == directory.path
        entries = updated
        loadedDirectory = directory

        // A reload that changes nothing must change nothing. The watcher fires
        // whenever anything in the folder is written, and in a cloud folder
        // that is often; reloading the table each time resets what the mouse is
        // in the middle of doing.
        if !unchanged {
            rebuildTable()
        }
        measureVisibleFolders()

        guard !entries.isEmpty else {
            // statusText(), not "empty folder": trashing the last file in a
            // folder announced what it did and then immediately overwrote it.
            statusLabel.stringValue = failure ?? statusText()
            // Still cleared: an empty folder is an answer to "reveal this",
            // and leaving the request pending would fire it at the next one.
            applyPendingSelection()
            return
        }

        statusLabel.stringValue = statusText()

        if pendingSelection?.folder.path == directory.path {
            // A reveal wins over the row that happened to be selected before:
            // some other application has just said "this one".
            applyPendingSelection()
        } else if unchanged {
            // Nothing moved, so the selection is already where it belongs and
            // setting it again would scroll the list out from under somebody.
        } else {
            // A remembered row may have been renamed or deleted by whatever
            // triggered this reload, so ending up with fewer than were
            // selected, or with none and falling back to the top, is normal.
            let wanted = Set(previousSelection)
            let rows = entries.indices.filter { wanted.contains(entries[$0].name) }
            select(rows: rows.isEmpty ? [0] : rows)
        }

        if let pending = pendingRename, let row = entries.firstIndex(where: { $0.url == pending }) {
            pendingRename = nil
            select(row: row)
            beginRename(row: row)
        }
    }

    /// Says what just happened, and keeps saying it for a moment.
    ///
    /// Every operation ends by re-reading the folder, and the reload sets the
    /// status line to the item count. So "copied, 3 items" was written and
    /// then wiped a few milliseconds later, every time, and the only channel
    /// this window has for telling somebody what it did said nothing.
    /// Says which appearance was just switched to.
    func announceAppearance(_ appearance: Appearance) {
        announce("appearance: \(appearance.title.lowercased())")
    }

    /// Says something went wrong, where somebody will see it.
    ///
    /// Both: the banner because it is unmissable, and the status line because
    /// that is where the last thing that happened lives.
    private func warn(_ message: String, kind: NoticeBanner.Kind = .warning) {
        banner.show(message, kind: kind)
        announce(message)
    }

    private func announce(_ message: String) {
        announcement = message
        announcementUntil = Date().addingTimeInterval(Self.announcementLifetime)
        // The one place that writes the label directly. Everything else goes
        // through here, or through statusText() when it is describing state
        // rather than reporting an event.
        statusLabel.stringValue = message
    }

    private func statusText() -> String {
        if let announcement, Date() < announcementUntil { return announcement }

        // What is selected wins over what is in the folder: once several rows
        // are picked, how many of them there are is the thing being asked.
        let selected = selectedEntries()
        if selected.count > 1 {
            let bytes = selected.compactMap(\.size).reduce(0, +)
            let size = bytes > 0 ? ", \(Self.sizeFormatter.string(fromByteCount: bytes))" : ""
            return "\(selected.count) of \(entries.count) selected\(size)"
        }

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

    /// The bar and the field share a slot. The bar is what you look at and
    /// click; the field is what you type into, and it appears when you ask.
    private func showPathField(_ editing: Bool) {
        pathBar.isHidden = editing
        pathField.isHidden = !editing

        // The button says what pressing it will do next, not what is on screen.
        pathToggle.image = NSImage(
            systemSymbolName: editing ? "list.bullet.indent" : "character.cursor.ibeam",
            accessibilityDescription: editing ? "Show the path as components" : "Type a path")
        pathToggle.toolTip =
            editing ? "Back to the clickable path" : "Type a path instead (⇧⌘G)"
    }

    @objc private func togglePathEditing(_ sender: Any?) {
        if pathField.isHidden {
            focusPathField(nil)
        } else {
            // Giving up focus is what ends editing, and ending editing is what
            // puts the bar back, so there is one route rather than two.
            view.window?.makeFirstResponder(tableView)
        }
    }

    @objc func focusSearch(_ sender: Any?) {
        view.window?.makeFirstResponder(searchField)
    }

    @objc fileprivate func searchChanged(_ sender: NSSearchField) {
        filter = sender.stringValue.trimmingCharacters(in: .whitespaces)
        entries = Self.filtered(allEntries, by: filter)
        rebuildTable()
        if !entries.isEmpty { select(row: 0) }
        statusLabel.stringValue = statusText()
    }

    private func select(row: Int) {
        select(rows: [row])
    }

    private func select(rows: [Int]) {
        let valid = rows.filter { entries.indices.contains($0) }
        guard let first = valid.first else { return }
        tableView.selectRowIndexes(IndexSet(valid), byExtendingSelection: false)
        // The first of them, so a restored selection scrolls to its top rather
        // than to wherever it happens to end.
        tableView.scrollRowToVisible(first)
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

    /// The first selected row, for the things that can only mean one file:
    /// renaming it, previewing which one to open with, asking what it is.
    private func selectedEntry() -> Entry? {
        selectedEntries().first
    }

    /// Everything selected, in the order it appears in the list.
    ///
    /// In list order rather than click order on purpose: a copy of five files
    /// and a report of what happened both read better top to bottom than in
    /// the order somebody happened to ⌘-click them.
    private func selectedEntries() -> [Entry] {
        tableView.selectedRowIndexes
            .filter { entries.indices.contains($0) }
            .map { entries[$0] }
    }

    /// What the actions work on: the selected rows, or the folder itself when
    /// nothing is selected. Copying "the path" with an empty list should still
    /// give you a path.
    private func actionTargets() -> [URL] {
        let selected = selectedEntries().map(\.url)
        return selected.isEmpty ? [directory] : selected
    }

    private func actionTarget() -> URL {
        actionTargets()[0]
    }

    /// ⌘↓ on a folder, and the context menu. Opening in a tab keeps where you
    /// were, which is the entire point of having tabs.
    @objc func openInNewTab(_ sender: Any?) {
        let folders = selectedEntries().filter(\.isDirectory)
        guard !folders.isEmpty else {
            NSSound.beep()
            return
        }
        for folder in folders { onNewTab?(folder.url) }
    }

    /// Return, and a double click.
    ///
    /// One folder is walked into, because that is what a browser is for.
    /// Several are opened as tabs, because there is nowhere else for them to
    /// go, and files are handed to whatever owns them.
    /// What a double click and Return both run, for the checks.
    func activateSelection() {
        openSelection()
    }

    @objc private func openSelection() {
        let selected = selectedEntries()
        guard !selected.isEmpty else { return }

        let folders = selected.filter(\.isDirectory)
        let files = selected.filter { !$0.isDirectory }

        if folders.count == 1, files.isEmpty {
            navigate(to: folders[0].url)
        } else {
            for folder in folders { onNewTab?(folder.url) }
        }
        for file in files { NSWorkspace.shared.open(file.url) }
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
        announce("connecting to \(share.host ?? share.absoluteString)…")

        ShareMounter.mount(share) { [weak self] result in
            guard let self else { return }
            switch result {
            case .alreadyMounted(let url):
                announce("already mounted")
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
                announce("asking the system for credentials")
                ShareMounter.askSystemToConnect(share)
            case .failed(let reason):
                NSSound.beep()
                announce(reason)
                pathField.stringValue = directory.path
            }
        }
    }

    /// ⌘K, which is the key everyone already presses for this.
    @objc func connectToServer(_ sender: Any?) {
        ConnectSheet.show(
            in: view.window, recents: favourites.servers(), preferences: preferences
        ) { [weak self] url, note in
            if let note { self?.statusLabel.stringValue = note }
            self?.connect(to: url)
        }
    }

    // MARK: - Menu actions

    @objc func focusPathField(_ sender: Any?) {
        // Shown first, because a hidden view cannot become first responder.
        // If it does not take focus it stays on screen anyway: a visible field
        // can be clicked into, and one that has been put away cannot.
        showPathField(true)
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

    /// ⇧⌘K, and the View menu. The same switch the header menu offers, put
    /// somewhere it can be found without knowing to right-click a header.
    @objc func toggleCreatedColumn(_ sender: Any?) {
        let item = NSMenuItem()
        item.representedObject = ListingColumn.created.rawValue
        toggleColumn(item)
    }

    /// Whether the Created column is on screen, for the checks.
    var showsCreatedColumn: Bool { visibleColumns.contains("created") }

    /// ⌘R. The one place folder sizes are thrown away.
    ///
    /// Not on every reload: the watcher fires whenever anything in the folder
    /// is written, and re-walking a tree on every save would make the column
    /// cost far more than it is worth. A size that has gone stale is corrected
    /// by asking, which is what this is.
    @objc func refresh(_ sender: Any?) {
        folderSizes.forget()
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
        announce(
            added
                ? "added \(target.lastPathComponent) to favourites"
                : "removed \(target.lastPathComponent) from favourites")
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
        let selected = selectedEntries()
        guard !selected.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // File URLs, so this works with Finder and everything else that deals
        // in files rather than only within this application.
        pasteboard.writeObjects(selected.map { $0.url as NSURL })
        announce(
            selected.count == 1
                ? "copied \(selected[0].name)"
                : "copied \(selected.count) items")
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
            announce("one transfer at a time, for now")
            return
        }
        if let refusal = Transfer.check(moving: sources, into: destination, kind: .copy) {
            NSSound.beep()
            announce(refusal.message)
            return
        }
        let plan = Transfer.plan(sources, into: destination, kind: .copy)
        transfers.start(plan, in: view.window) { [weak self] outcome in
            self?.finished(outcome, kind: .copy)
        }
    }

    private func transfer(kind: Transfer.Kind) {
        guard !transfers.isRunning else {
            announce("one transfer at a time, for now")
            return
        }

        let sources = pasteboardURLs()
        guard !sources.isEmpty else {
            announce("nothing on the clipboard to paste")
            return
        }

        if let refusal = Transfer.check(moving: sources, into: directory, kind: kind) {
            NSSound.beep()
            announce(refusal.message)
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
        announce(parts.joined(separator: ", "))
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
            announce("created \(name)")
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

    /// One at a time: there is one field editor and one name being typed into
    /// it. Renaming several is a different feature with a different dialog.
    @objc func renameSelection(_ sender: Any?) {
        guard let entry = selectedEntry(), let row = entries.firstIndex(of: entry) else { return }
        beginRename(row: row)
    }

    @objc func moveToTrash(_ sender: Any?) {
        let selected = selectedEntries()
        guard !selected.isEmpty else { return }

        // What actually reached the trash, so undo puts back exactly that and
        // a failure part way through still restores the part that worked.
        var moved: [(original: URL, inTrash: URL)] = []
        // Counted separately, because the system does not always say where
        // something landed. Undo needs the destination and so only gets the
        // ones that have it; the count is about what actually went, and
        // leaving those out made the message say nothing at all.
        var goneCount = 0
        var refused: [(name: String, reason: String)] = []

        // Every one of them, rather than stopping at the first refusal, and
        // through the checked call rather than the plain one: macOS will not
        // let ~/Documents and its kind go to the trash, and it refuses by
        // reporting success and doing nothing.
        for entry in selected {
            switch FileOperations.trashChecking(entry.url) {
            case .moved(let landed):
                goneCount += 1
                if let landed {
                    moved.append((original: entry.url, inTrash: landed))
                }
            case .refused(let reason):
                refused.append((name: entry.name, reason: reason))
            }
        }

        registerTrashUndo(moved)
        reload(keepingSelection: true)

        var parts: [String] = []
        if goneCount > 0 {
            parts.append(
                goneCount == 1 && moved.count == 1
                    ? "moved \(moved[0].original.lastPathComponent) to the trash"
                    : "moved \(goneCount) items to the trash")
        }
        if !refused.isEmpty {
            NSSound.beep()
            // Named when there are few enough to read, counted when there are
            // not, and the reason either way: "3 refused" on its own is a
            // dead end. Every distinct reason, because two folders refused for
            // two different reasons is two things worth knowing.
            let names =
                refused.count <= 3
                ? refused.map(\.name).joined(separator: ", ")
                : "\(refused.count) items"
            let reasons = Set(refused.map(\.reason)).sorted().joined(separator: "; ")
            parts.append("could not move \(names): \(reasons)")
        }
        // Never nothing: a command that ran and said neither what it did nor
        // why it did not is the worst of the three.
        let message =
            parts.isEmpty
            ? "nothing was moved to the trash" : parts.joined(separator: "; ")

        // The banner only when something was refused. A trash that worked is
        // not worth a band across the window.
        if refused.isEmpty {
            announce(message)
        } else {
            warn(message)
        }
    }

    private func registerTrashUndo(_ items: [(original: URL, inTrash: URL)]) {
        guard !items.isEmpty else { return }
        registerUndo("Move to Trash") { controller in
            controller.attempt(Self.describe(putting: items)) {
                // Deepest last in, first out: a folder cannot be put back
                // before the thing it used to live in.
                for item in items.reversed() {
                    try FileManager.default.moveItem(at: item.inTrash, to: item.original)
                }
            }
            controller.registerUndo("Move to Trash") { controller in
                var again: [(original: URL, inTrash: URL)] = []
                controller.attempt("move them to the trash again") {
                    for item in items {
                        if let trashed = try FileOperations.trash(item.original) {
                            again.append((original: item.original, inTrash: trashed))
                        }
                    }
                }
                controller.registerTrashUndo(again)
            }
        }
    }

    private static func describe(putting items: [(original: URL, inTrash: URL)]) -> String {
        items.count == 1
            ? "put \(items[0].original.lastPathComponent) back"
            : "put \(items.count) items back"
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
        warn("could not \(what): \(error.localizedDescription)", kind: .failure)
    }

    @objc func copyPath(_ sender: Any?) {
        let targets = actionTargets()
        // One path per line, which is what a shell, an editor and a chat
        // message all want from a list of files.
        Actions.copyPaths(targets)
        announce(
            targets.count == 1 ? "copied \(targets[0].path)" : "copied \(targets.count) paths")
    }

    /// ⇧⌘R. Deliberately Finder, not "the system's file viewer": inside pfadi
    /// the only reason to reach for this is to get to Finder, and once pfadi is
    /// the file viewer the polite call comes straight back here.
    @objc func showInFinder(_ sender: Any?) {
        Actions.showInFinder(actionTargets())
    }

    /// Which application took the request, for the checks.
    func showInFinder(reporting handled: @escaping (String?) -> Void) {
        Actions.showInFinder(actionTargets(), handled: handled)
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
        if menuItem.action == #selector(toggleCreatedColumn(_:)) {
            menuItem.state = preferences.columns.contains(.created) ? .on : .off
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
            return selectedEntries().contains(where: \.isDirectory)
        }
        // Renaming is the one that stays singular: there is one field editor
        // and one name being typed into it.
        if menuItem.action == #selector(renameSelection(_:)) {
            return selectedEntries().count == 1
        }
        if menuItem.action == #selector(copy(_:))
            || menuItem.action == #selector(moveToTrash(_:))
        {
            return !selectedEntries().isEmpty
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
        // The count in the status line is part of the selection, so it moves
        // with it rather than only when the folder is re-read.
        statusLabel.stringValue = statusText()

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

        guard let column = ListingColumn(rawValue: tableColumn.identifier.rawValue) else {
            return nil
        }
        if column == .name {
            return nameCell(for: entry, in: tableView)
        }
        return textCell(
            text(for: entry, in: column),
            in: tableView,
            aligned: column.isRightAligned ? .right : .left)
    }

    /// What a cell says.
    ///
    /// Blank rather than a dash wherever the filesystem records nothing: not
    /// every volume has a creation date or tags, and an SMB share answering
    /// with nothing is normal rather than something worth drawing attention to.
    private func text(for entry: Entry, in column: ListingColumn) -> String {
        switch column {
        case .name:
            return entry.name
        case .size:
            var text =
                entry.isDirectory
                ? folderSizeText(entry)
                : entry.size.map(Self.sizeFormatter.string) ?? ""
            // A placeholder has a size and no bytes. Saying so here is the
            // difference between copying a folder and downloading it.
            if entry.cloud.isCloud, !entry.cloud.isDownloaded {
                text = "\u{2601} \(text)"
            }
            return text
        case .files:
            // From the walk that measures the size, so it costs nothing extra
            // and appears at the same moment.
            guard entry.isDirectory, let measured = folderSizes.cached(entry.url) else { return "" }
            return measured.complete ? "\(measured.files)" : "over \(measured.files)"
        case .modified:
            return entry.modified.map(Self.dateFormatter.string) ?? ""
        case .created:
            return entry.created.map(Self.dateFormatter.string) ?? ""
        case .added:
            return entry.added.map(Self.dateFormatter.string) ?? ""
        case .opened:
            return entry.opened.map(Self.dateFormatter.string) ?? ""
        case .kind:
            return entry.kind ?? ""
        case .fileExtension:
            return entry.url.pathExtension
        case .tags:
            return entry.tags.joined(separator: ", ")
        case .permissions:
            return entry.permissions ?? ""
        case .owner:
            return entry.owner ?? ""
        }
    }

    /// Sorts with the folder sizes this window has measured.
    ///
    /// PfadiCore cannot do it alone: a folder has no size on disk, so sorting
    /// by size left every folder pinned to the top of the list in name order,
    /// which looks exactly like a sort that does not work.
    private func resorted(_ listing: [Entry]) -> [Entry] {
        guard order.key == .size else {
            return DirectoryListing.sorted(listing, by: order)
        }
        return DirectoryListing.sorted(listing, by: order) { [folderSizes] entry in
            entry.isDirectory ? folderSizes.cached(entry.url)?.bytes : entry.size
        }
    }

    /// Puts the rows back in order once a folder has been measured.
    ///
    /// Only while sorting by size, and coalesced: measurements arrive one per
    /// folder, and re-sorting on each of them would have rows jumping under the
    /// pointer all the way down a large folder.
    private func resortLater() {
        guard order.key == .size, !resortScheduled else { return }
        resortScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            resortScheduled = false
            guard order.key == .size else { return }
            let selected = selectedEntries().map(\.name)
            allEntries = resorted(allEntries)
            entries = Self.filtered(allEntries, by: filter)
            rebuildTable()
            let wanted = Set(selected)
            select(rows: entries.indices.filter { wanted.contains(self.entries[$0].name) })
        }
    }

    /// What goes in the size column for a folder.
    ///
    /// An en dash until the walk finishes, because a folder's size is not
    /// something the filesystem knows and pretending otherwise means either
    /// blocking the list or lying. "over" when the walk gave up at its limit:
    /// the number is then a floor, and saying so is the difference between an
    /// answer and a guess.
    private func folderSizeText(_ entry: Entry) -> String {
        let unknown = "\u{2013}"
        guard let measured = folderSizes.cached(entry.url) else { return unknown }
        // Nothing counted and not finished means the folder could not be read
        // at all. "over Zero KB" would be a number where there is none.
        guard measured.complete || measured.files > 0 else { return unknown }

        let size = Self.sizeFormatter.string(fromByteCount: measured.bytes)
        return measured.complete ? size : "over \(size)"
    }

    /// Asks for the sizes of the folders somebody can currently see.
    private func measureVisibleFolders() {
        // Sorting by size is the one case where the rows on screen are not
        // enough: an order worked out from the folders that happen to be
        // visible is not an order at all.
        if order.key == .size {
            folderSizes.want(entries.filter(\.isDirectory).map(\.url))
            return
        }

        var visible = tableView.rows(in: tableView.visibleRect)
        if visible.length == 0 {
            // Before the first layout pass there is no visible rect to speak
            // of. What will be visible is the top of the list, so start there
            // rather than measuring nothing until the first scroll.
            visible = NSRange(location: 0, length: min(entries.count, 40))
        }
        // Clamped both ends. rows(in:) answers about the table's last layout,
        // which can describe more rows than the list now holds, and an
        // inverted Range is a trap rather than an empty one.
        let lower = min(max(visible.location, 0), entries.count)
        let upper = min(visible.location + visible.length, entries.count)
        let rows = lower..<max(lower, upper)
        folderSizes.want(rows.compactMap { entries[$0].isDirectory ? entries[$0].url : nil })
    }

    /// The one place the table is rebuilt, so it can be counted.
    private func rebuildTable() {
        reloadCount += 1
        tableView.reloadData()
    }

    /// Puts a measurement into the cells that show it, without rebuilding them.
    ///
    /// `reloadData(forRowIndexes:columnIndexes:)` makes new cell views, and a
    /// cell replaced under the pointer breaks the click sequence in progress.
    /// In a folder with two dozen subfolders the measurements arrive in a
    /// steady trickle, so a double click had to be tried three times before one
    /// of them landed between two of them.
    private func redrawSize(of url: URL) {
        guard let row = entries.firstIndex(where: { $0.url == url }) else { return }
        let entry = entries[row]

        for listed in [ListingColumn.size, .files] {
            let index = tableView.column(
                withIdentifier: NSUserInterfaceItemIdentifier(listed.rawValue))
            guard index >= 0, !tableView.tableColumns[index].isHidden else { continue }
            // makeIfNecessary: false, so a row that has scrolled away is left
            // alone: it will be built with the right text when it comes back.
            guard
                let cell = tableView.view(atColumn: index, row: row, makeIfNecessary: false)
                    as? NSTableCellView
            else { continue }
            cell.textField?.stringValue = text(for: entry, in: listed)
        }
    }

    private func nameCell(for entry: Entry, in tableView: NSTableView) -> NSView {
        let id = NSUserInterfaceItemIdentifier("nameCell")
        let cell =
            tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
            ?? Self.makeNameCell(id: id)

        cell.imageView?.image = FileIcons.icon(for: entry.url, isDirectory: entry.isDirectory)
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

    /// Every selected file, so the panel's own arrows walk the selection.
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedEntries().count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let selected = selectedEntries()
        guard selected.indices.contains(index) else { return nil }
        return selected[index].url as (any QLPreviewItem)?
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
        guard let field = notification.object as? NSTextField else { return }

        // Not the path field: that one is its own delegate and reports through
        // onEndEditing instead, because these notifications never reach here
        // for it.
        guard field !== pathField else { return }
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
            announce("renamed to \(name)")
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
        if menu === headerMenu {
            // A tick against every column that is on, so the menu says what is
            // showing as well as what could be.
            for item in menu.items {
                guard let identifier = item.representedObject as? String else { continue }
                let index = tableView.column(
                    withIdentifier: NSUserInterfaceItemIdentifier(identifier))
                item.state = index >= 0 && !tableView.tableColumns[index].isHidden ? .on : .off
                // Name is not optional, so it is shown ticked and inert rather
                // than offered and then refused.
                item.isEnabled = identifier != "name"
            }
            return
        }

        let clicked = tableView.clickedRow
        // A right-click inside an existing selection acts on the whole of it;
        // one outside starts a new selection of the row that was clicked.
        // Anything else means right-clicking one of five selected files
        // quietly throws the other four away.
        if entries.indices.contains(clicked), !tableView.selectedRowIndexes.contains(clicked) {
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

        let destination = dropDestination(row: row, operation: operation)
        if destination.path == directory.path {
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

        let destination = dropDestination(row: row, operation: operation)
        return drop(sources, into: destination, kind: kind(for: info, into: destination))
    }

    /// Where a drop at this row lands.
    ///
    /// Dropping between rows means "into the folder on screen"; dropping on a
    /// row means that row, but only when it is a folder. Shared by validate and
    /// accept, which used to work it out separately and could in principle
    /// disagree about where the files were going.
    func dropDestination(row: Int, operation: NSTableView.DropOperation) -> URL {
        if operation == .on, entries.indices.contains(row), entries[row].isDirectory {
            return entries[row].url
        }
        return directory
    }

    /// Carries out a drop. Every source, not the first one: a drag that started
    /// from five selected rows arrives here as five URLs.
    @discardableResult
    func drop(_ sources: [URL], into destination: URL, kind transferKind: Transfer.Kind) -> Bool {
        guard !transfers.isRunning else {
            announce("one transfer at a time, for now")
            return false
        }
        if let refusal = Transfer.check(moving: sources, into: destination, kind: transferKind) {
            NSSound.beep()
            announce(refusal.message)
            return false
        }

        let plan = Transfer.plan(sources, into: destination, kind: transferKind)
        transfers.start(plan, in: view.window) { [weak self] outcome in
            self?.finished(outcome, kind: transferKind)
        }
        return true
    }

    /// Every file URL on the drag's pasteboard.
    ///
    /// AppKit asks `pasteboardWriterForRow` once per selected row when a drag
    /// starts inside a selection, so a five-row drag really does arrive with
    /// five URLs on it, and reading only the first would silently drop four.
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
