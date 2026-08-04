import AppKit
import PfadiCore

/// ⌘I: what this thing is.
///
/// A panel rather than a window, so it floats over the browser and does not
/// take a place in the window menu for something you glance at.
final class InfoPanel {
    private var panel: NSPanel?
    private let stack = NSStackView()

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    func show(_ url: URL, relativeTo window: NSWindow?) {
        let panel = panel ?? makePanel()
        self.panel = panel

        let info = FileInfo.gather(url)
        panel.title = info.name
        fill(with: info)

        if panel.isVisible {
            panel.orderFront(nil)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Called when the selection moves, so an open panel keeps up rather than
    /// describing whatever was selected when it opened.
    func update(_ url: URL?) {
        guard let panel, panel.isVisible else { return }
        guard let url else {
            panel.orderOut(nil)
            return
        }
        let info = FileInfo.gather(url)
        panel.title = info.name
        fill(with: info)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor, constant: -18),
        ])
        panel.contentView = content
        return panel
    }

    private func fill(with info: FileInfo) {
        for view in stack.arrangedSubviews {
            view.removeFromSuperview()
        }

        var rows: [(String, String)] = []
        rows.append(("Kind", info.kind ?? (info.isDirectory ? "Folder" : "Unknown")))

        if let status = info.cloud.summary {
            rows.append(("Cloud", status))
        }
        if !info.isDirectory {
            // A folder's size means walking it, which on a cloud folder means
            // asking about every placeholder inside. Not for a panel that
            // opens on a keystroke.
            rows.append(("Size", info.size.map(Self.sizeFormatter.string) ?? "unknown"))
        }
        if let created = info.created {
            rows.append(("Created", Self.dateFormatter.string(from: created)))
        }
        if let modified = info.modified {
            rows.append(("Modified", Self.dateFormatter.string(from: modified)))
        }
        if let permissions = info.permissions {
            let owner = [info.owner, info.group].compactMap { $0 }.joined(separator: ":")
            rows.append(("Access", owner.isEmpty ? permissions : "\(permissions)  \(owner)"))
        }
        rows.append(("Where", info.url.deletingLastPathComponent().path))

        for (label, value) in rows {
            stack.addArrangedSubview(Self.row(label: label, value: value))
        }
    }

    private static func row(label: String, value: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8

        let name = NSTextField(labelWithString: label)
        name.font = .systemFont(ofSize: 11, weight: .semibold)
        name.textColor = .secondaryLabelColor
        name.alignment = .right
        name.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        name.widthAnchor.constraint(equalToConstant: 68).isActive = true

        let content = NSTextField(labelWithString: value)
        content.font = .systemFont(ofSize: 12)
        content.lineBreakMode = .byTruncatingMiddle
        // Selectable, because the first thing anyone does with a path in a
        // panel like this is try to copy it.
        content.isSelectable = true

        row.addArrangedSubview(name)
        row.addArrangedSubview(content)
        return row
    }
}
