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
    /// A double click on a row.
    ///
    /// Not `doubleAction`, which asks NSTableView whether both clicks belonged
    /// to the same row by its own bookkeeping. That bookkeeping is disturbed by
    /// anything that touches the rows in between — a cell rebuilt as a folder
    /// measurement lands, a reload from the watcher — so opening a folder in a
    /// busy directory became a matter of luck. `clickCount` is on the event
    /// itself and does not care what the table did with its views.
    var onDoubleClick: ((Int) -> Void)?
    var onTypeAhead: ((String) -> Void)?
    var onSpace: (() -> Void)?

    private var buffer = ""
    private var lastKeystroke: TimeInterval = 0

    override func mouseDown(with event: NSEvent) {
        // A bare double click only. ⌘-clicking the same row twice quickly is
        // somebody toggling it out of a selection and back, and opening it for
        // them would be infuriating; ⇧ is extending a range.
        guard event.clickCount >= 2,
            !event.modifierFlags.intersects([.command, .shift, .option, .control])
        else {
            super.mouseDown(with: event)
            return
        }
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        // On a row, not on the empty space below the last one, which would
        // otherwise open whatever happened to still be selected.
        guard row >= 0 else {
            super.mouseDown(with: event)
            return
        }

        // Deliberately without calling super. The first click already selected
        // the row, and NSTableView's mouseDown runs a tracking loop for drag
        // detection that has nothing to do here and would only wait for a
        // mouse-up that has already been and gone.
        onDoubleClick?(row)
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
