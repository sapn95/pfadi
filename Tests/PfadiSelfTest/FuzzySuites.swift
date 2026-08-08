import Foundation
import PfadiCore

/// The one match every filter in pfadi uses.
enum FuzzySuites {
    static func run() {
        matching()
        ranking()
    }

    private static func matching() {
        Harness.suite("fuzzy: letters in order, not necessarily together") {
            // The reason it is not `contains`. Somebody with thirty favourites
            // types the initials of the one they want, and `dwn` matches
            // nothing at all under a substring search.
            Harness.expect(FuzzyMatch.matches("dwn", "Downloads"), "dwn finds Downloads")
            Harness.expect(FuzzyMatch.matches("doc", "Documents"), "doc finds Documents")
            Harness.expect(
                FuzzyMatch.matches("cfg", "eslintrc.config.js"), "cfg finds a config file")
        }

        Harness.suite("fuzzy: out of order is not a match") {
            // Subsequence, not "contains these letters". Otherwise every query
            // matches nearly everything and the filter stops narrowing.
            Harness.expect(!FuzzyMatch.matches("nwd", "Downloads"), "nwd is not Downloads")
            Harness.expect(
                !FuzzyMatch.matches("xyz", "Documents"), "nor is a letter that is absent")
            Harness.expect(
                !FuzzyMatch.matches("documents extra", "Documents"),
                "and a query longer than the name cannot fit inside it")
        }

        Harness.suite("fuzzy: an empty query matches everything") {
            Harness.expect(FuzzyMatch.matches("", "anything"), "an empty box filters nothing")
            Harness.expectEqual(
                FuzzyMatch.filter(["a", "b"], query: "") { $0 }, ["a", "b"],
                "and leaves the order alone")
        }

        Harness.suite("fuzzy: accents and case are folded away") {
            Harness.expect(FuzzyMatch.matches("zurich", "Zürich"), "uber finds über")
            Harness.expect(FuzzyMatch.matches("DOC", "Documents"), "and case does not matter")
            Harness.expect(
                FuzzyMatch.matches("uber", "Übersicht"), "including at the start of a word")
        }

        Harness.suite("fuzzy: a name whose folding changes its length still matches") {
            // "ß" folds to "ss", so the folded text is longer than the
            // original and the positions no longer line up. It must match
            // rather than crash or silently fail.
            Harness.expect(FuzzyMatch.matches("stra", "Straße"), "the part before it")
            Harness.expect(FuzzyMatch.matches("strasse", "Straße"), "and the folded spelling")
        }
    }

    private static func ranking() {
        Harness.suite("fuzzy: the closest match comes first") {
            let names = ["Downloads for Docker", "Documents", "Dock"]
            Harness.expectEqual(
                FuzzyMatch.filter(names, query: "doc") { $0 }.first, "Dock",
                "letters together and at the front beat letters scattered")
        }

        Harness.suite("fuzzy: a run beats the same letters spread out") {
            let names = ["a-b-c-config", "config"]
            Harness.expectEqual(
                FuzzyMatch.filter(names, query: "config") { $0 }.first, "config",
                "the whole word wins")
        }

        Harness.suite("fuzzy: the start of a word counts for something") {
            let names = ["undocumented", "Documents"]
            Harness.expectEqual(
                FuzzyMatch.filter(names, query: "doc") { $0 }.first, "Documents",
                "rather than the same letters buried in the middle")
        }

        Harness.suite("fuzzy: ties keep the order they came in") {
            // A list somebody arranged themselves keeps its arrangement when
            // the query is not discriminating enough to change it.
            let names = ["report-a", "report-b", "report-c"]
            Harness.expectEqual(
                FuzzyMatch.filter(names, query: "report") { $0 }, names,
                "nothing is shuffled for no reason")
        }

        Harness.suite("fuzzy: what does not match is dropped, not sorted last") {
            Harness.expectEqual(
                FuzzyMatch.filter(["Documents", "Music"], query: "doc") { $0 }, ["Documents"],
                "a filter narrows rather than reorders")
        }
    }
}
