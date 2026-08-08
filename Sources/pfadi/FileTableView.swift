import AppKit
import PfadiCore

/// A table that treats return as "open this" and letters as "find this",
/// rather than as the start of a rename.
final class FileTableView: NSTableView {
    /// Forgets a half-typed name. Called when the folder changes: a prefix
    /// describes the list it was typed into and means nothing in the next one.
    func resetTypeAhead() {
        buffer = ""
        lastKeystroke = 0
    }

    var onReturn: (() -> Void)?
    /// Whether a click may put a cell into editing.
    ///
    /// Answered by the controller, which knows whether a rename was asked for.
    /// This is the hook AppKit provides for it, and using it is what lets the
    /// table go back to deciding double clicks for itself.
    var shouldBeginEditing: ((NSResponder) -> Bool)?
    var onTypeAhead: ((String) -> Void)?
    var onSpace: (() -> Void)?

    private var buffer = ""
    private var lastKeystroke: TimeInterval = 0

    /// AppKit asks this before letting a click start editing a cell.
    ///
    /// Its default says yes for any view in a selected row, so clicking the
    /// name of a row that is already selected begins a rename — and the click
    /// that started it is consumed, which is why a double click on a selected
    /// folder sometimes did nothing at all. Renaming here is asked for
    /// deliberately, with F2 or from the menu, so nothing else may start one.
    override func validateProposedFirstResponder(
        _ responder: NSResponder,
        for event: NSEvent?
    ) -> Bool {
        // Not a mouse event: the field editor being installed by editColumn,
        // or the keyboard moving focus. Neither is a click to be protected
        // from.
        guard let event, event.type == .leftMouseDown || event.type == .rightMouseDown else {
            return super.validateProposedFirstResponder(responder, for: event)
        }
        return shouldBeginEditing?(responder) ?? false
    }

    override func keyDown(with event: NSEvent) {
        // 36 is return, 76 is enter on the numeric keypad.
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
            return
        }

        // A bare space is Quick Look, unless a name is actually being typed
        // right now, in which case it belongs to the name. A buffer left over
        // from a minute ago is not somebody typing.
        if event.charactersIgnoringModifiers == " ",
            !event.modifierFlags.intersects([.command, .control, .option, .shift]),
            buffer.isEmpty
                || !TypeAhead.isLive(
                    lastKeystroke: lastKeystroke, now: Date().timeIntervalSinceReferenceDate)
        {
            // Holding the key down would otherwise open and close the panel
            // several times a second.
            if !event.isARepeat {
                buffer = ""
                onSpace?()
            }
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

        // A bare space is handled above as Quick Look. It only counts as
        // input once it is part of a name being typed.
        if scalar == " ", buffer.isEmpty { return nil }

        return characters
    }
}

extension NSEvent.ModifierFlags {
    fileprivate func intersects(_ other: NSEvent.ModifierFlags) -> Bool {
        !intersection(other).isEmpty
    }
}
