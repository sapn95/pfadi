import AppKit
import PfadiCore

/// Asking for a share in a way that helps rather than assuming you know the
/// spelling.
///
/// The path field takes `smb://server/share` and always will, but nobody
/// should have to know that to reach a filer. The protocol is a button, the
/// rest is one field, and the shape it expects is written underneath it.
enum ConnectSheet {
    private struct Scheme {
        let name: String
        let scheme: String
        let placeholder: String
        let hint: String
    }

    private static let schemes = [
        Scheme(
            name: "SMB",
            scheme: "smb",
            placeholder: "server/share",
            hint: "Windows and NAS shares. smb://server/share"
        ),
        Scheme(
            name: "NFS",
            scheme: "nfs",
            placeholder: "server/export/path",
            hint: "Unix exports. nfs://server/export, the path the server exports"
        ),
        Scheme(
            name: "AFP",
            scheme: "afp",
            placeholder: "server/share",
            hint: "Older Macs and Time Capsules. afp://server/share"
        ),
    ]

    /// Shows the sheet and hands back a URL, or nothing if it was cancelled.
    static func show(
        in window: NSWindow?,
        recents: [URL],
        preferences: Preferences = Preferences(),
        then use: @escaping (URL, _ note: String?) -> Void
    ) {
        let picker = NSSegmentedControl(
            labels: schemes.map(\.name), trackingMode: .selectOne, target: nil, action: nil)
        picker.selectedSegment = 0

        let field = NSTextField()
        field.placeholderString = schemes[0].placeholder
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        let hint = NSTextField(labelWithString: schemes[0].hint)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.preferredMaxLayoutWidth = 360

        let magic = NSButton(
            checkboxWithTitle: "Understand pasted addresses", target: nil, action: nil)
        magic.state = preferences.rewriteAddresses ? .on : .off
        magic.toolTip =
            "Turns \\\\server\\share and //server/share into an address. "
            + "Off means only a real smb:// or nfs:// is accepted."

        // A list, not a popup button.
        //
        // The popup showed each address as its whole absoluteString, changed
        // its own title to whatever was picked so the label was gone after the
        // first use, and could only be reached with the mouse. With a dozen
        // filers it was the worst control in the application.
        let known = KnownConnections(servers: recents)
        known.isHidden = recents.isEmpty

        // The controls talk to each other rather than to the caller, so the
        // sheet stays a value in and a value out.
        let coordinator = Coordinator(picker: picker, field: field, hint: hint)
        picker.target = coordinator
        picker.action = #selector(Coordinator.schemeChanged)
        known.onChoose = { [weak coordinator] url in
            coordinator?.use(url)
        }

        // Grouped rather than evenly spaced: the field belongs to the protocol
        // above it and the hint belongs to the field, so those sit close and
        // the breaks go between the groups.
        let entry = NSStackView(views: [picker, field, hint])
        entry.orientation = .vertical
        entry.alignment = .leading
        entry.spacing = 6
        entry.setCustomSpacing(10, after: picker)

        let stack = NSStackView(views: [entry, known, magic])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        known.widthAnchor.constraint(equalToConstant: 360).isActive = true
        hint.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true

        // Sized to what it holds, then given that as a frame. An accessory
        // view with a guessed height leaves a gap above it in the sheet.
        stack.layoutSubtreeIfNeeded()
        let fitting = stack.fittingSize
        stack.translatesAutoresizingMaskIntoConstraints = true
        stack.frame = NSRect(origin: .zero, size: fitting)

        let alert = NSAlert()
        alert.messageText = "Connect to Server"
        alert.informativeText = "Or type the same thing into the path bar, if you know it."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            // Keep the coordinator alive until the sheet is gone.
            withExtendedLifetime(coordinator) {}
            guard response == .alertFirstButtonReturn else { return }

            let rewriting = magic.state == .on
            preferences.rewriteAddresses = rewriting

            guard
                let read = NetworkShare.interpret(
                    field.stringValue,
                    scheme: schemes[picker.selectedSegment].scheme,
                    rewriting: rewriting)
            else {
                NSSound.beep()
                return
            }
            // Say what was made of it. Silently changing what somebody typed
            // is how they end up not trusting the field.
            let note = read.rewrittenFrom.map { "read \($0) as \(read.url.absoluteString)" }
            use(read.url, note)
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: handler)
            window.makeFirstResponder(field)
        } else {
            handler(alert.runModal())
        }
    }

    private final class Coordinator: NSObject {
        private let picker: NSSegmentedControl
        private let field: NSTextField
        private let hint: NSTextField

        init(picker: NSSegmentedControl, field: NSTextField, hint: NSTextField) {
            self.picker = picker
            self.field = field
            self.hint = hint
        }

        @objc func schemeChanged() {
            let scheme = ConnectSheet.schemes[picker.selectedSegment]
            field.placeholderString = scheme.placeholder
            hint.stringValue = scheme.hint
        }

        /// Fills the field in from something picked out of the list.
        func use(_ url: URL) {
            // The button follows, so the field and the button never disagree
            // about which protocol this is.
            if let index = ConnectSheet.schemes.firstIndex(where: { $0.scheme == url.scheme }) {
                picker.selectedSegment = index
                schemeChanged()
            }
            // The user with it. It was dropped, so picking a share you connect
            // to as somebody else put you back to guessing, or to the wrong
            // account.
            let user = url.user.map { "\($0)@" } ?? ""
            field.stringValue = user + (url.host ?? "") + url.path
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }
}
