import AppKit
import PfadiCore

/// A table that treats return as "open this" and letters as "find this",
/// rather than as the start of a rename.
final class FileTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onTypeAhead: ((String) -> Void)?

    private var buffer = ""
    private var lastKeystroke: TimeInterval = 0

    override func keyDown(with event: NSEvent) {
        // 36 is return, 76 is enter on the numeric keypad.
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
            return
        }

        if let typed = typeAheadCharacter(in: event) {
            let now = Date().timeIntervalSinceReferenceDate
            buffer = TypeAhead.buffer(
                buffer, appending: typed, lastKeystroke: lastKeystroke, now: now)
            lastKeystroke = now
            onTypeAhead?(buffer)
            return
        }

        buffer = ""
        super.keyDown(with: event)
    }

    /// The character to search for, or nil when the key means something else.
    private func typeAheadCharacter(in event: NSEvent) -> String? {
        guard !event.modifierFlags.intersects([.command, .control, .option]) else { return nil }
        guard let characters = event.charactersIgnoringModifiers,
            let scalar = characters.unicodeScalars.first
        else { return nil }

        // Below 0x20 is control characters, 0xF700 upwards is where AppKit puts
        // the arrow and function keys. Neither is something anyone is spelling.
        guard scalar.value >= 0x20, scalar.value < 0xF700 else { return nil }

        // A bare space scrolls, and will one day open Quick Look. It only
        // counts as input once it is part of a name being typed.
        if scalar == " ", buffer.isEmpty { return nil }

        return characters
    }
}

extension NSEvent.ModifierFlags {
    fileprivate func intersects(_ other: NSEvent.ModifierFlags) -> Bool {
        !intersection(other).isEmpty
    }
}
