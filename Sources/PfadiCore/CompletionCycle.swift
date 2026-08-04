import Foundation

/// Tab walks through the matches one at a time, the way a shell does it.
///
/// A dropdown list makes you take your hands off the keyboard to choose. A
/// cycle keeps everything on tab: press it until the name you want is in the
/// field, then commit.
public struct CompletionCycle: Equatable {
    /// Everything up to and including the last slash. Never rewritten.
    public let prefix: String
    /// What was actually typed, kept so escape can put it back.
    public let partial: String
    public let candidates: [String]
    public private(set) var index: Int

    /// Fails when nothing matches, which the caller should say out loud rather
    /// than swallow. Silence after a tab is indistinguishable from a broken key.
    public init?(
        text: String,
        showHidden: Bool,
        base: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let (prefix, partial) = Self.split(text)
        let candidates = PathCompletion.candidates(
            prefix: prefix,
            partial: partial,
            showHidden: showHidden,
            base: base,
            fileManager: fileManager
        )
        guard !candidates.isEmpty else { return nil }

        self.prefix = prefix
        self.partial = partial
        self.candidates = candidates
        self.index = 0
    }

    /// The full path as it should now read in the field.
    public var text: String { prefix + candidates[index] }

    /// What was in the field before tab was ever pressed.
    public var original: String { prefix + partial }

    public var isSingle: Bool { candidates.count == 1 }

    /// `2 of 7`, for a person who wants to know how much is left to walk past.
    public var position: String { "\(index + 1) of \(candidates.count)" }

    /// Wraps in both directions, so shift-tab off the front lands on the back.
    public mutating func advance(by step: Int) {
        let count = candidates.count
        index = ((index + step) % count + count) % count
    }

    /// Splits a typed path into the part that stays and the part being completed.
    ///
    /// `~/git/bern` is `~/git/` plus `bern`. A text with no slash at all is
    /// entirely a name being completed against the current folder.
    public static func split(_ text: String) -> (prefix: String, partial: String) {
        guard let slash = text.lastIndex(of: "/") else { return ("", text) }
        let cut = text.index(after: slash)
        return (String(text[..<cut]), String(text[cut...]))
    }
}
