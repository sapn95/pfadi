import AppKit

/// The back and forward arrows in the title bar.
///
/// A toolbar rather than two buttons inside the content view: it puts them
/// where every other application on this system puts them, and the sidebar
/// slides underneath it properly.
final class NavigationToolbar: NSObject, NSToolbarDelegate {
    private static let arrows = NSToolbarItem.Identifier("navigation")

    var onBack: (() -> Void)?
    var onForward: (() -> Void)?

    private let control = NSSegmentedControl()

    func makeToolbar() -> NSToolbar {
        control.segmentCount = 2
        control.trackingMode = .momentary
        control.segmentStyle = .separated
        control.setImage(
            NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back"),
            forSegment: 0)
        control.setImage(
            NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: "Forward"),
            forSegment: 1)
        control.target = self
        control.action = #selector(segmentClicked(_:))
        update(canGoBack: false, canGoForward: false)

        let toolbar = NSToolbar(identifier: "io.github.sapn95.pfadi.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    /// Greys out an arrow with nowhere to go, rather than letting it beep.
    func update(canGoBack: Bool, canGoForward: Bool) {
        control.setEnabled(canGoBack, forSegment: 0)
        control.setEnabled(canGoForward, forSegment: 1)
    }

    @objc private func segmentClicked(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? onBack?() : onForward?()
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard identifier == Self.arrows else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Back/Forward"
        item.view = control
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // sidebarTrackingSeparator keeps the arrows aligned with the content
        // pane rather than drifting over the sidebar as it is resized.
        [.toggleSidebar, .sidebarTrackingSeparator, Self.arrows]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
}
