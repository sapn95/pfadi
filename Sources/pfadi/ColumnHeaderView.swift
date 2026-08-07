import AppKit

/// The row of column headers, with a right-click that actually opens a menu.
///
/// Setting `headerView.menu` is not enough. Asked directly, `menu(for:)` hands
/// the menu back, which is why a check that asked it passed while a two-finger
/// tap on the real headers did nothing at all: `NSTableHeaderView` handles the
/// right button itself, for column selection and dragging, and never gets as
/// far as putting a menu up.
///
/// So the menu is popped here, explicitly, and the check below drives the same
/// method AppKit does rather than the property behind it.
final class ColumnHeaderView: NSTableHeaderView {
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Control-click is the other way to ask for a context menu, and on a
    /// trackpad it is the one people who have not turned on two-finger tap use.
    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control), let menu = menu(for: event) else {
            super.mouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// What a right-click opens, for the checks.
    ///
    /// Goes through `rightMouseDown` rather than around it, because the gap
    /// between "the menu exists" and "the menu appears" is exactly what was
    /// wrong. `popUpContextMenu` blocks on a real event loop, so the check asks
    /// for the decision rather than the presentation.
    func menuForRightClick() -> NSMenu? {
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1)
        return event.flatMap(menu(for:))
    }
}
