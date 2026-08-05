import AppKit

/// The box the path lives in, and everything that belongs to it.
///
/// One control rather than four things in a line. The box stays put and its
/// contents change: components and an arrow when you are looking, a text field
/// when you are typing, and the button that switches between them always in
/// the same place at the right of it.
///
/// The path control is only as wide as its components, which is what puts the
/// arrow right after the last folder. That leaves nothing inside it to
/// double-click, so the box is this view instead and the empty part of it is
/// what takes that click.
final class PathRow: NSView {
    /// A double click on the empty part: somebody who wants to type a path.
    var onEdit: (() -> Void)?

    private let bar: PathBar
    private let descend: NSButton
    private let field: PathField
    private let toggle = NSButton()

    private(set) var isEditing = false

    init(bar: PathBar, descend: NSButton, field: PathField) {
        self.bar = bar
        self.descend = descend
        self.field = field
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        applyControlColours()

        // The box draws the edge, so the field must not draw a second one
        // inside it.
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none

        toggle.bezelStyle = .accessoryBar
        toggle.isBordered = false
        toggle.target = self
        toggle.action = #selector(toggleClicked)

        for view in [bar, descend, field, toggle] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.widthAnchor.constraint(equalToConstant: 22),

            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),

            descend.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 2),
            descend.trailingAnchor.constraint(
                lessThanOrEqualTo: toggle.leadingAnchor, constant: -4),
            descend.centerYAnchor.constraint(equalTo: centerYAnchor),
            descend.widthAnchor.constraint(equalToConstant: 22),

            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            field.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        showEditing(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("pfadi builds its views in code")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 24)
    }

    func showEditing(_ editing: Bool) {
        isEditing = editing
        bar.isHidden = editing
        descend.isHidden = editing
        field.isHidden = !editing

        // The button says what pressing it will do next, not what is on screen.
        toggle.image = NSImage(
            systemSymbolName: editing ? "list.bullet.indent" : "character.cursor.ibeam",
            accessibilityDescription: editing ? "Show the path as folders" : "Type a path")
        toggle.toolTip = editing ? "Back to the clickable path" : "Type a path instead (⇧⌘G)"
    }

    @objc private func toggleClicked() {
        onEdit?()
    }

    override func mouseDown(with event: NSEvent) {
        // Only the empty part. A click that landed on the components, the arrow
        // or the button is theirs, and they will have taken it before this.
        guard event.clickCount == 2, !isEditing else {
            super.mouseDown(with: event)
            return
        }
        onEdit?()
    }

    /// The same fill and edge the text field used to draw for itself, so the
    /// box reads as the control it replaced rather than as a new thing.
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
}
