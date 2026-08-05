import AppKit
import PfadiCore

/// The path as clickable components, with a filtered menu of everything that
/// sits at the same level behind each one.
///
/// `/Users/sapn/git/pfadi` is four buttons. Clicking `git` offers everything
/// in `~`, including `git` itself, with a filter field at the top for when
/// there are two hundred of them. It is how you step sideways without retyping
/// the path, which is the thing a text field alone cannot do.
final class PathBar: NSPathControl {
    /// Somewhere to go, chosen from a component's menu.
    var onChoose: ((URL) -> Void)?
    /// Whether hidden folders appear in the menus. Follows the list.
    var showHidden = false

    /// Asked for by a double click on the bar itself rather than on a folder:
    /// somebody who wants to type a path.
    var onEdit: (() -> Void)?

    /// The folder being shown.
    ///
    /// NSPathControlItem carries a read-only URL, so items cannot be built by
    /// hand and still be navigable. The control keeps making its own from this,
    /// and the arrow that goes deeper is a button beside it instead.
    var directory: URL? {
        didSet { url = directory }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pathStyle = .standard
        focusRingType = .none
        doubleAction = #selector(componentOpened)
        toolTip =
            "Click a folder for what is beside it, double-click to go there. "
            + "Double-click the bar itself to type a path."

        // Drawn as a control rather than as loose text. Before this it read as
        // a label somebody had left above the list, and nothing about it said
        // it could be clicked.
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        applyControlColours()
        target = self
        action = #selector(componentClicked)
        // Nothing is dropped on the bar itself; the list and the sidebar take
        // drops, and a third target with different rules would be a trap.
        unregisterDraggedTypes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("pfadi builds its views in code")
    }

    /// Double click on a component goes there. Typing is the button at the end
    /// of the row and ⇧⌘G, which are both deliberate acts rather than the
    /// second half of a click somebody was already making.
    @objc private func componentOpened() {
        // A double click that missed every folder is a double click on the bar,
        // and the bar is the thing that turns into a text field.
        guard let url = clickedPathItem?.url else {
            onEdit?()
            return
        }
        onChoose?(url)
    }

    /// The same fill and edge the text field has, so the two read as one slot
    /// that switches rather than as two different things.
    private func applyControlColours() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // CGColor does not follow a change between light and dark, so the
        // colours are taken again rather than left as whatever they were.
        effectiveAppearance.performAsCurrentDrawingAppearance { [weak self] in
            self?.applyControlColours()
        }
    }

    @objc private func componentClicked() {
        // A click that landed on the control but not on a component does
        // nothing. It used to swap in the text field, which is a one-way door
        // if the field never takes focus.
        guard let item = clickedPathItem, let url = item.url else { return }
        presentSiblings(of: url)
    }

    /// What is inside the folder on screen, rather than what is beside it.
    /// Shown from the arrow that sits after the last component.
    func presentContents(from view: NSView) {
        guard let directory else { return }
        present(folders(in: directory), ticking: nil, below: view)
    }

    /// The menu behind one component: everything beside it, and itself.
    private func presentSiblings(of url: URL) {
        present(folders(in: url.deletingLastPathComponent()), ticking: url, below: self)
    }

    private func present(_ siblings: [URL], ticking: URL?, below anchor: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Only worth a filter when there is something to filter. A search box
        // above four items is furniture.
        let filter = siblings.count > 8 ? FilterView(menu: menu) : nil
        if let filter {
            let item = NSMenuItem()
            item.view = filter
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let build: (String) -> Void = { [weak self] text in
            guard let self else { return }
            // Everything after the filter is rebuilt; the filter itself stays
            // where it is so typing into it is not interrupted.
            let keep = filter == nil ? 0 : 2
            while menu.numberOfItems > keep { menu.removeItem(at: keep) }

            let matching =
                text.isEmpty
                ? siblings
                : siblings.filter {
                    $0.lastPathComponent.range(
                        of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }

            guard !matching.isEmpty else {
                let empty = menu.addItem(
                    withTitle: siblings.isEmpty ? "no folders in here" : "no match",
                    action: nil, keyEquivalent: "")
                empty.isEnabled = false
                return
            }

            for sibling in matching {
                let item = menu.addItem(
                    withTitle: sibling.lastPathComponent,
                    action: #selector(self.siblingChosen(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = sibling
                item.image = NSWorkspace.shared.icon(forFile: sibling.path)
                item.image?.size = NSSize(width: 16, height: 16)
                // The one that was clicked is ticked, so the menu says where
                // you are as well as where you could go. Nothing is ticked
                // when the menu is about going deeper: none of it is here.
                item.state = sibling.path == ticking?.path ? .on : .off
            }
        }

        filter?.onChange = build
        build("")

        let position = NSPoint(x: 0, y: anchor.bounds.height + 4)
        menu.popUp(positioning: nil, at: position, in: anchor)
    }

    @objc private func siblingChosen(_ sender: NSMenuItem) {
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

/// The filter field that sits at the top of a component's menu.
private final class FilterView: NSView, NSSearchFieldDelegate {
    var onChange: ((String) -> Void)?

    private let field = NSSearchField()

    init(menu: NSMenu) {
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
