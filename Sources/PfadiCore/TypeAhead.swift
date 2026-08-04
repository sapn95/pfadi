import Foundation

/// Jump to a row by typing its name.
///
/// In a folder with a hundred repositories, typing `terra` beats scrolling by
/// a wide margin. The rules are the ones every list on this platform uses, and
/// people notice immediately when they are wrong.
public enum TypeAhead {
    /// How long a typed prefix stays alive before the next keystroke starts over.
    public static let timeout: TimeInterval = 1.0

    /// The row matching `prefix`.
    ///
    /// A single character cycles: pressing `t` again moves to the next entry
    /// starting with `t`, which is how you walk through a run of similar names.
    /// Two or more characters are a refinement, not a step, so the search
    /// restarts from the top and lands on the same row every time.
    ///
    /// Matching ignores case and diacritics, so `uber` finds `Über`.
    public static func index(
        matching prefix: String,
        in names: [String],
        current: Int?
    ) -> Int? {
        guard !prefix.isEmpty, !names.isEmpty else { return nil }

        let cycling = prefix.count == 1
        let start = cycling ? (current.map { $0 + 1 } ?? 0) : 0
        let order =
            cycling
            ? Array(start..<names.count) + Array(0..<start)
            : Array(0..<names.count)

        return order.first { names[$0].hasPrefixIgnoringCaseAndDiacritics(prefix) }
    }

    /// Whether a keystroke continues the current prefix or begins a new one.
    public static func buffer(
        _ existing: String,
        appending character: String,
        lastKeystroke: TimeInterval,
        now: TimeInterval
    ) -> String {
        guard now - lastKeystroke <= timeout else { return character }
        // Pressing the same single letter again means "the next one starting
        // with this", which is how everybody walks a run of similar names.
        // Appending would make it "tt" and search for a name nobody has.
        if existing == character { return character }
        return existing + character
    }

    /// Whether a keystroke still belongs to the prefix being typed.
    ///
    /// A stale buffer is not a prefix any more, which matters for space: it is
    /// part of a name while one is being typed, and Quick Look otherwise.
    public static func isLive(lastKeystroke: TimeInterval, now: TimeInterval) -> Bool {
        now - lastKeystroke <= timeout
    }
}

extension String {
    fileprivate func hasPrefixIgnoringCaseAndDiacritics(_ prefix: String) -> Bool {
        range(of: prefix, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
    }
}
