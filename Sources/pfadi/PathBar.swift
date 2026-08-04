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
    /// Asked for when somebody clicks past the end of the path: they want to
    /// type, and the text field is what takes typing.
    var onEdit: (() -> Void)?

    /// Whether hidden folders appear in the menus. Follows the list.
    var showHidden = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pathStyle = .standard
        focusRingType = .none
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

    @objc private func componentClicked() {
        guard let item = clickedPathItem, let url = item.url else {
            onEdit?()
            return
        }
        presentSiblings(of: url)
    }

    /// The menu behind one component: everything beside it, and itself.
    private func presentSiblings(of url: URL) {
        let parent = url.deletingLastPathComponent()
        let siblings = folders(in: parent)

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
                let empty = menu.addItem(withTitle: "no match", action: nil, keyEquivalent: "")
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
                // you are as well as where you could go.
                item.state = sibling.path == url.path ? .on : .off
            }
        }

        filter?.onChange = build
        build("")

        let position = NSPoint(x: 0, y: bounds.height + 4)
        menu.popUp(positioning: nil, at: position, in: self)
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
