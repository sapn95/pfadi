import AppKit
import PfadiCore

/// The address bar. Click it, type, press tab, press return.
///
/// AppKit gives a text field completion for free, but only on escape and only
/// if the delegate supplies candidates. Tab has to be taken over by hand,
/// because the field editor would otherwise move focus to the next view.
final class PathField: NSTextField, NSTextFieldDelegate {
    /// Whether hidden entries take part in completion. Follows the list.
    var showHidden = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("pfadi builds its views in code")
    }

    private func configure() {
        delegate = self
        font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        placeholderString = "/path/to/somewhere"
        isBezeled = true
        bezelStyle = .roundedBezel
        focusRingType = .default
        // A path is not prose: the system would otherwise capitalise it,
        // curl the quotes and helpfully correct `/usr/bin` into something else.
        isAutomaticTextCompletionEnabled = false
        if let editor = currentEditor() as? NSTextView {
            editor.isAutomaticTextReplacementEnabled = false
        }
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.insertTab(_:)) else { return false }
        textView.complete(nil)
        return true
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        completions words: [String],
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String] {
        let text = textView.string as NSString
        guard charRange.location <= text.length else { return [] }

        let partial = text.substring(with: charRange)
        let prefix = text.substring(to: charRange.location)

        return PathCompletion.candidates(
            prefix: prefix,
            partial: partial,
            showHidden: showHidden
        )
    }
}
