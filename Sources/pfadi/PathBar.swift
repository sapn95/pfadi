import AppKit
import PfadiCore

/// The path as clickable folders, with a filtered menu behind each one.
///
/// Built out of buttons rather than an NSPathControl. That control reports the
/// same intrinsic width whatever it is showing, sixty points for one folder or
/// for ten, so nothing beside it can be placed relative to its contents and
/// everything around it is free to drift. That is what put the arrow at the far
/// right of the row and made the whole layout ambiguous. Buttons know how wide
/// they are, which makes the row determinate and lands the arrow exactly after
/// the last folder.
final class PathBar: NSView {
    /// Somewhere to go: a folder chosen from a menu, or double-clicked.
    var onChoose: ((URL) -> Void)?
    /// A double click on the empty part: somebody who wants to type a path.
    var onEdit: (() -> Void)?
    /// Whether hidden folders appear in the menus. Follows the list.
    var showHidden = false

    var directory: URL? {
        didSet {
            guard directory?.path != oldValue?.path else { return }
            rebuild()
        }
    }

    private let stack = NSStackView()
    private var componentButtons: [NSButton] = []
    private let overflow = NSButton()
    private let descend = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.masksToBounds = true

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])

        configure(overflow, title: "…")
        overflow.action = #selector(overflowClicked)
        overflow.toolTip = "The folders that do not fit"

        configure(descend, title: "")
        descend.image = NSImage(
            systemSymbolName: "chevron.right", accessibilityDescription: "Go into a folder")
        descend.action = #selector(descendClicked)
        descend.toolTip = "What is inside this folder"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("pfadi builds its views in code")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 22)
    }

    /// A double click on the empty part asks for the text field. A click on a
    /// button never reaches here, so this only ever means "not on a folder".
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else {
            super.mouseDown(with: event)
            return
        }
        onEdit?()
    }

    // MARK: - Building

    private func configure(_ button: NSButton, title: String) {
        button.title = title
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .systemFont(ofSize: 12)
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.target = self
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    /// The folders the bar is showing, for the checks. A root that is in the
    /// model and missing from the row is the failure this catches.
    func drawnComponents() -> [String] {
        componentButtons.compactMap { $0.identifier?.rawValue }
    }

    private func rebuild() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        componentButtons = []

        guard let directory else { return }

        // All the way to the root. Stopping at home hides the folders above
        // it, and a path that quietly begins in the middle is a path you have
        // to think about before you can trust it. When it does not fit, the
        // leading folders fold into the ellipsis, which still opens them.
        var chain: [URL] = []
        var current = directory.standardizedFileURL
        while true {
            chain.append(current)
            if current.path == "/" { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }

        stack.addArrangedSubview(overflow)
        overflow.isHidden = true

        for (index, url) in chain.reversed().enumerated() {
            if index > 0 {
                stack.addArrangedSubview(separator())
            }
            let button = NSButton()
            configure(button, title: FileManager.default.displayName(atPath: url.path))
            button.image = NSWorkspace.shared.icon(forFile: url.path)
            button.image?.size = NSSize(width: 14, height: 14)
            button.action = #selector(componentClicked(_:))
            // The URL travels with the button, so nothing has to work out
            // afterwards which index a click belonged to.
            button.identifier = NSUserInterfaceItemIdentifier(url.path)
            componentButtons.append(button)
            stack.addArrangedSubview(button)
        }

        stack.addArrangedSubview(descend)
        needsLayout = true
    }

    private func separator() -> NSView {
        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        return chevron
    }

    /// Drops folders off the front until the rest fits, and says so with an
    /// ellipsis. Losing the far end would lose where you are; losing the near
    /// end only loses what the menu can still reach.
    override func layout() {
        super.layout()
        guard componentButtons.count > 1 else { return }

        let available = bounds.width - 8
        for view in stack.arrangedSubviews where view !== overflow {
            view.isHidden = false
        }
        overflow.isHidden = true

        // The order folders give way in: the ones just after the root first,
        // then the root itself, and never the last one. The root is how you
        // get to /etc and /Volumes, so it is the last thing worth losing, and
        // the far end is where you actually are.
        let count = componentButtons.count
        let order = Array(1..<max(1, count - 1)) + (count > 1 ? [0] : [])

        for index in order {
            guard stack.fittingSize.width > available else { break }
            overflow.isHidden = false
            let button = componentButtons[index]
            button.isHidden = true
            if let position = stack.arrangedSubviews.firstIndex(of: button), position > 1 {
                // The separator in front of it goes too, or the row keeps a
                // chevron pointing at nothing.
                stack.arrangedSubviews[position - 1].isHidden = true
            }
        }
    }

    // MARK: - Clicks

    @objc private func componentClicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)

        // A double click goes there, a single one asks what else is at that
        // level. Both are useful and neither should need a modifier.
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            onChoose?(url)
            return
        }

        // The root has no siblings: it is where the path begins, and its
        // parent is itself. A menu of what is inside it is the arrow's job, so
        // clicking it goes there instead. Without this the leftmost folder is
        // the one thing in the bar you cannot click your way to.
        guard !PathCompletion.isRoot(url) else {
            onChoose?(url)
            return
        }
        present(folders(in: url.deletingLastPathComponent()), below: sender)
    }

    @objc private func descendClicked() {
        guard let directory else { return }
        present(folders(in: directory), below: descend)
    }

    @objc private func overflowClicked() {
        // In path order rather than the order they were dropped, so the menu
        // reads the way the bar would have.
        let urls = componentButtons.filter(\.isHidden)
            .compactMap { $0.identifier?.rawValue }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        present(urls, below: overflow)
    }

    // MARK: - Menus

    /// One menu, whichever part of the path was clicked.
    ///
    /// Always with the filter, never with a tick. A menu that is sometimes a
    /// plain list and sometimes a searchable one means looking first and
    /// reacting second, every time. The same shape every time means typing
    /// straight away without checking what you got.
    private func present(_ folders: [URL], below anchor: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let filter = FilterView()
        let filterItem = NSMenuItem()
        filterItem.view = filter
        menu.addItem(filterItem)
        menu.addItem(.separator())

        let build: (String) -> Void = { [weak self] text in
            guard let self else { return }
            let keep = 2
            while menu.numberOfItems > keep { menu.removeItem(at: keep) }

            let matching =
                text.isEmpty
                ? folders
                : folders.filter {
                    $0.lastPathComponent.range(
                        of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }

            guard !matching.isEmpty else {
                let empty = menu.addItem(
                    withTitle: folders.isEmpty ? "no folders in here" : "no match",
                    action: nil, keyEquivalent: "")
                empty.isEnabled = false
                return
            }

            for folder in matching {
                let item = menu.addItem(
                    withTitle: folder.lastPathComponent,
                    action: #selector(self.folderChosen(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = folder
                item.image = NSWorkspace.shared.icon(forFile: folder.path)
                item.image?.size = NSSize(width: 16, height: 16)
            }
        }

        filter.onChange = build
        build("")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    @objc private func folderChosen(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onChoose?(url)
    }

    private func folders(in directory: URL) -> [URL] {
        var options: FileManager.DirectoryEnumerationOptions = []
        if !showHidden { options.insert(.skipsHiddenFiles) }

        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: options)) ?? []

        return
            contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
    }
}

/// The filter field that sits at the top of a folder menu.
private final class FilterView: NSView, NSSearchFieldDelegate {
    var onChange: ((String) -> Void)?

    private let field = NSSearchField()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        field.frame = NSRect(x: 14, y: 4, width: 214, height: 22)
        field.placeholderString = "Filter"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("pfadi builds its views in code")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A filter you have to click into first is slower than scrolling past
        // the thing you wanted.
        window?.makeFirstResponder(field)
    }

    func controlTextDidChange(_ notification: Notification) {
        onChange?(field.stringValue)
    }
}
