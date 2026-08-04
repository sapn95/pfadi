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
        then use: @escaping (URL) -> Void
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

        let previous = NSPopUpButton()
        previous.addItem(withTitle: "Recent servers")
        for url in recents {
            previous.addItem(withTitle: url.absoluteString)
        }
        previous.isHidden = recents.isEmpty

        // The controls talk to each other rather than to the caller, so the
        // sheet stays a value in and a value out.
        let coordinator = Coordinator(picker: picker, field: field, hint: hint, previous: previous)
        picker.target = coordinator
        picker.action = #selector(Coordinator.schemeChanged)
        previous.target = coordinator
        previous.action = #selector(Coordinator.recentChosen)

        let stack = NSStackView(views: [picker, field, hint, previous])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 108)
        field.widthAnchor.constraint(equalToConstant: 340).isActive = true
        previous.widthAnchor.constraint(equalToConstant: 340).isActive = true

        let alert = NSAlert()
        alert.messageText = "Connect to Server"
        alert.informativeText =
            "The path field takes the same thing, if you already know how it is spelled."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            // Keep the coordinator alive until the sheet is gone.
            withExtendedLifetime(coordinator) {}
            guard response == .alertFirstButtonReturn else { return }
            guard
                let url = assemble(scheme: schemes[picker.selectedSegment], from: field.stringValue)
            else {
                NSSound.beep()
                return
            }
            use(url)
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: handler)
            window.makeFirstResponder(field)
        } else {
            handler(alert.runModal())
        }
    }

    private static func assemble(scheme: Scheme, from input: String) -> URL? {
        NetworkShare.assemble(scheme: scheme.scheme, from: input)
    }

    private final class Coordinator: NSObject {
        private let picker: NSSegmentedControl
        private let field: NSTextField
        private let hint: NSTextField
        private let previous: NSPopUpButton

        init(
            picker: NSSegmentedControl, field: NSTextField, hint: NSTextField,
            previous: NSPopUpButton
        ) {
            self.picker = picker
            self.field = field
            self.hint = hint
            self.previous = previous
        }

        @objc func schemeChanged() {
            let scheme = ConnectSheet.schemes[picker.selectedSegment]
            field.placeholderString = scheme.placeholder
            hint.stringValue = scheme.hint
        }

        @objc func recentChosen() {
            guard previous.indexOfSelectedItem > 0,
                let title = previous.titleOfSelectedItem,
                let url = URL(string: title)
            else { return }

            // Set the button to match what was picked, so the field and the
            // button never disagree about which protocol this is.
            if let index = ConnectSheet.schemes.firstIndex(where: { $0.scheme == url.scheme }) {
                picker.selectedSegment = index
                schemeChanged()
            }
            field.stringValue = (url.host ?? "") + url.path
        }
    }
}
