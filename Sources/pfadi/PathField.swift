import AppKit
import PfadiCore

/// The address bar. Click it, type, tab until the name you want is there,
/// return to accept it, return again to go.
///
/// AppKit's own completion is a dropdown you have to look at and choose from.
/// This walks the matches inline instead, one per tab, which keeps a path being
/// assembled entirely under the keyboard.
final class PathField: NSTextField, NSTextFieldDelegate {
    /// Whether hidden entries take part in completion. Follows the list.
    var showHidden = false

    /// What a relative path is relative to. Without it, typing `sub/` and
    /// pressing tab offers nothing, while committing the same text navigates.
    var currentDirectory: URL?

    /// Progress through the matches, or nil once there is nothing to report.
    var onCompletionChanged: ((String?) -> Void)?

    private var cycle: CompletionCycle?
    private var isApplyingCompletion = false

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

    /// True while tab has left a suggestion in the field that has not been
    /// accepted. The first return accepts it, the second one commits the path.
    var isCompleting: Bool { cycle != nil }

    func endCompletion() {
        guard cycle != nil else { return }
        cycle = nil
        onCompletionChanged?(nil)
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

    func controlTextDidChange(_ notification: Notification) {
        // Typing anything means the old set of matches is about a different
        // word. Rewriting the field during a cycle is not typing, though.
        guard !isApplyingCompletion else { return }
        endCompletion()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            step(by: 1)
            return true

        case #selector(NSResponder.insertBacktab(_:)):
            step(by: -1)
            return true

        case #selector(NSResponder.insertNewline(_:)):
            // The first return accepts the suggestion and stays put, so the
            // next tab can carry on into the folder that was just chosen. The
            // second return falls through to the field's action and navigates.
            guard isCompleting else { return false }
            endCompletion()
            return true

        case #selector(NSResponder.cancelOperation(_:)):
            guard let cycle else { return false }
            apply(cycle.original)
            endCompletion()
            return true

        default:
            return false
        }
    }

    private func step(by direction: Int) {
        if cycle != nil {
            cycle?.advance(by: direction)
        } else {
            cycle = CompletionCycle(
                text: stringValue, showHidden: showHidden, base: currentDirectory)
        }

        guard let cycle else {
            NSSound.beep()
            onCompletionChanged?("no match")
            return
        }

        apply(cycle.text)
        // One match is not a list to walk through, so say what it was and stop
        // holding a cycle open for a second tab that has nowhere to go.
        onCompletionChanged?(cycle.isSingle ? cycle.candidates[0] : cycle.position)
        if cycle.isSingle {
            self.cycle = nil
        }
    }

    /// What is on screen right now.
    ///
    /// While the field is being edited that is the field editor, not
    /// `stringValue`: the cell only catches up when editing ends through the
    /// usual route. Anything acting on "what the person sees" has to ask here.
    var typedText: String {
        currentEditor()?.string ?? stringValue
    }

    private func apply(_ text: String) {
        isApplyingCompletion = true
        defer { isApplyingCompletion = false }

        // Both, and in this order. Writing only to the field editor leaves the
        // cell holding whatever was there before, so committing navigates to
        // the old text and the field redraws empty the moment focus leaves.
        stringValue = text
        if let editor = currentEditor() {
            editor.string = text
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
    }
}
