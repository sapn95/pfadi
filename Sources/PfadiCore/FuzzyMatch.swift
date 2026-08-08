import Foundation

/// Matching the way people type into a search box: `dwn` finds `Downloads`.
///
/// A substring match is not enough for a sidebar. Somebody with thirty
/// favourites types the initials of the one they want, not a run of letters
/// from the middle of it, and `dwn` matches nothing at all under `contains`.
///
/// The rule is subsequence: every character of the query appears in the
/// candidate, in order, not necessarily together. What makes it usable rather
/// than merely permissive is the score, which prefers matches that start a word
/// and matches whose letters are next to each other — so `doc` puts `Documents`
/// above `Downloads for Docker`, which it also matches.
public enum FuzzyMatch {
    /// How well `query` matches `candidate`, or nothing when it does not.
    ///
    /// Higher is better. The number means nothing on its own; it is only ever
    /// compared with another score for the same query.
    public static func score(_ query: String, _ candidate: String) -> Int? {
        // An empty query matches everything equally, which is what an empty
        // search box should do.
        guard !query.isEmpty else { return 0 }

        // Folded, so `uber` finds `über` and `Zurich` finds `Zürich`. The
        // unfolded original is kept for the word-start test, which reads case.
        let needle = Array(fold(query))
        let hay = Array(fold(candidate))
        let original = Array(candidate)
        // Folding can change the length — "ß" becomes "ss" — so the positions
        // below index the folded text and only ever compare with each other.
        guard hay.count == original.count else {
            return looseScore(needle: needle, hay: hay, candidate: candidate)
        }
        guard needle.count <= hay.count else { return nil }

        var total = 0
        var index = 0
        var previous = -2

        for character in needle {
            // Skip ahead to the next place this character appears. Leftmost
            // rather than best: a full search of every arrangement costs more
            // than a sidebar is worth, and the bonuses below already push the
            // sensible reading to the top.
            guard let found = hay[index...].firstIndex(of: character) else { return nil }

            total += 1
            if found == previous + 1 {
                // Next to the last one. This is what separates "Documents" for
                // `doc` from a name that merely happens to contain d, o and c.
                total += 8
            }
            if found == 0 {
                total += 12
            } else if isWordStart(original, at: found) {
                total += 6
            }

            previous = found
            index = hay.index(after: found)
        }

        // Shorter names win among equals: with `doc` matching both, "Documents"
        // is more likely to be meant than "Documents from the old laptop".
        return total - candidate.count / 4
    }

    /// Whether the query matches at all, without caring how well.
    ///
    /// For the file list, which keeps whatever order its sort column says: a
    /// filter that reordered the rows would fight the header somebody clicked.
    public static func matches(_ query: String, _ candidate: String) -> Bool {
        score(query, candidate) != nil
    }

    /// Lower case, and accents folded away.
    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// The same rule without the position bonuses, for the rare name whose
    /// folded form is a different length from the original.
    private static func looseScore(needle: [Character], hay: [Character], candidate: String)
        -> Int?
    {
        var index = hay.startIndex
        for character in needle {
            guard let found = hay[index...].firstIndex(of: character) else { return nil }
            index = hay.index(after: found)
        }
        return needle.count - candidate.count / 4
    }

    /// Whether the character at `offset` begins a word.
    ///
    /// After a separator, or a capital following a lower-case letter, which is
    /// how `pDoc` finds `projectDocuments`.
    private static func isWordStart(_ characters: [Character], at offset: Int) -> Bool {
        guard offset > 0 else { return true }
        let previous = characters[offset - 1]
        if previous == " " || previous == "-" || previous == "_" || previous == "." {
            return true
        }
        return characters[offset].isUppercase && previous.isLowercase
    }

    /// Keeps what matches, best first.
    ///
    /// Ties are broken by the original order rather than by name, so a list
    /// somebody has arranged themselves keeps its arrangement when the query is
    /// not discriminating enough to change it.
    public static func filter<T>(
        _ items: [T],
        query: String,
        name: (T) -> String
    ) -> [T] {
        guard !query.isEmpty else { return items }

        // Spelled out rather than chained. The one-expression version of this
        // defeated the type checker, and a build that takes minutes to fail is
        // worse than four extra lines.
        var scored: [(offset: Int, item: T, score: Int)] = []
        for (offset, item) in items.enumerated() {
            guard let score = score(query, name(item)) else { continue }
            scored.append((offset: offset, item: item, score: score))
        }

        scored.sort { left, right in
            left.score == right.score ? left.offset < right.offset : left.score > right.score
        }
        return scored.map(\.item)
    }
}
