import AppKit
import UniformTypeIdentifiers

/// The applications that will open a file, and which one does it by default.
enum OpenWith {
    struct Candidate {
        let url: URL
        let name: String
        let isDefault: Bool
    }

    /// Everything registered for this file, default first, then by name.
    static func candidates(for url: URL) -> [Candidate] {
        let workspace = NSWorkspace.shared
        let preferred = workspace.urlForApplication(toOpen: url)

        return
            workspace.urlsForApplications(toOpen: url)
            .map { app in
                Candidate(
                    url: app,
                    name: FileManager.default.displayName(atPath: app.path)
                        .replacingOccurrences(of: ".app", with: ""),
                    isDefault: app == preferred
                )
            }
            .sorted { left, right in
                if left.isDefault != right.isDefault { return left.isDefault }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }

    static func open(_ url: URL, with application: URL) {
        NSWorkspace.shared.open(
            [url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Makes an application the default for everything of this kind.
    ///
    /// The whole kind, not this one file: that is what the system offers, and
    /// it is why the menu item says so rather than hiding behind "Always".
    static func setDefault(
        _ application: URL,
        forKindOf url: URL,
        completion: @escaping (String) -> Void
    ) {
        guard
            let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        else {
            completion("could not work out what kind of file that is")
            return
        }

        NSWorkspace.shared.setDefaultApplication(at: application, toOpen: type) { error in
            let name = FileManager.default.displayName(atPath: application.path)
                .replacingOccurrences(of: ".app", with: "")
            let kind = type.localizedDescription ?? type.identifier
            DispatchQueue.main.async {
                if let error {
                    completion("could not set the default: \(error.localizedDescription)")
                } else {
                    completion("\(name) now opens every \(kind)")
                }
            }
        }
    }

    /// The system's own "choose an application" panel, for when the list does
    /// not have what you want.
    static func chooseApplication(
        for url: URL, in window: NSWindow?, then use: @escaping (URL) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.message = "Choose an application to open \(url.lastPathComponent)"
        panel.prompt = "Open"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let chosen = panel.url else { return }
            use(chosen)
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }
}
