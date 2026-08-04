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

    /// What a relative path is relative to. Without it, typing `sub/` and
    /// pressing tab offers nothing, while committing the same text navigates.
    var currentDirectory: URL?

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
        isAutomaticTextCompletionEnabled = false
    }

    /// A path is not prose: left alone the system capitalises it, curls the
    /// quotes and helpfully corrects `/usr/bin` into something else.
    ///
    /// This has to happen here rather than in `configure()`. The field editor
    /// is shared and created on demand, so at initialisation `currentEditor()`
    /// is nil and setting anything on it does nothing at all.
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
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
            showHidden: showHidden,
            base: currentDirectory
        )
    }
}
