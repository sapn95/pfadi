import AppKit

/// A table that treats return as "open this" instead of "start renaming".
final class FileTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // 36 is return, 76 is the enter key on the numeric keypad.
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }
}
