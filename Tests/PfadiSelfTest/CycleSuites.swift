import Foundation
import PfadiCore

/// Tab walking through the matches, one press at a time.
enum CycleSuites {
    static func run() {
        splitting()
        walking()
    }

    private static func splitting() {
        Harness.suite("split: what stays and what gets completed") {
            var parts = CompletionCycle.split("~/git/bern")
            Harness.expectEqual(parts.prefix, "~/git/", "everything up to the last slash stays")
            Harness.expectEqual(parts.partial, "bern", "the tail is what is being completed")

            parts = CompletionCycle.split("bern")
            Harness.expectEqual(parts.prefix, "", "no slash means no fixed part")
            Harness.expectEqual(parts.partial, "bern", "and the whole text is the word")

            parts = CompletionCycle.split("/Users/sapn/")
            Harness.expectEqual(parts.prefix, "/Users/sapn/", "a trailing slash keeps everything")
            Harness.expectEqual(parts.partial, "", "and completes against the folder itself")

            parts = CompletionCycle.split("")
            Harness.expectEqual(parts.prefix, "", "empty in")
            Harness.expectEqual(parts.partial, "", "empty out")
        }
    }

    private static func walking() {
        Harness.suite("cycle: tab walks forward and wraps") {
            try withSandbox(
                ["alpha", "beta", "gamma"], directories: ["alpha", "beta", "gamma"]
            ) { root in
                guard var cycle = CompletionCycle(text: root.path + "/", showHidden: false) else {
                    Harness.expect(false, "a folder with three entries produces a cycle")
                    return
                }

                Harness.expectEqual(cycle.candidates, ["alpha/", "beta/", "gamma/"], "all three")
                Harness.expectEqual(cycle.position, "1 of 3", "starts at the first")
                Harness.expectEqual(cycle.text, root.path + "/alpha/", "and shows it")

                cycle.advance(by: 1)
                Harness.expectEqual(cycle.text, root.path + "/beta/", "tab moves on")
                cycle.advance(by: 1)
                cycle.advance(by: 1)
                Harness.expectEqual(cycle.text, root.path + "/alpha/", "past the end it wraps")

                cycle.advance(by: -1)
                Harness.expectEqual(
                    cycle.text, root.path + "/gamma/", "shift-tab off the front wraps too")
            }
        }

        Harness.suite("cycle: a typed prefix narrows the walk") {
            try withSandbox(
                ["berlin.txt", "berndeutsch", "zurich.txt"], directories: ["berndeutsch"]
            ) { root in
                guard let cycle = CompletionCycle(text: root.path + "/ber", showHidden: false)
                else {
                    Harness.expect(false, "two entries start with ber")
                    return
                }
                Harness.expectEqual(cycle.candidates, ["berlin.txt", "berndeutsch/"], "just those")
                Harness.expectEqual(
                    cycle.original, root.path + "/ber", "escape can put back what was typed")
                Harness.expect(!cycle.isSingle, "two matches is a list")
            }
        }

        Harness.suite("cycle: one match is not a list") {
            try withSandbox(["unique.txt", "other.txt"]) { root in
                let cycle = CompletionCycle(text: root.path + "/uni", showHidden: false)
                Harness.expect(cycle?.isSingle == true, "a single match reports itself as one")
            }
        }

        Harness.suite("cycle: nothing matching produces nothing at all") {
            try withSandbox(["a.txt"]) { root in
                Harness.expect(
                    CompletionCycle(text: root.path + "/zzz", showHidden: false) == nil,
                    "no match means no cycle, so the caller can say so out loud")
                Harness.expect(
                    CompletionCycle(text: "/lalala/lalalal/", showHidden: false) == nil,
                    "a path that does not exist at all is the same story")
            }
        }

        Harness.suite("cycle: a relative word walks the current folder") {
            try withSandbox(["sub", "second"], directories: ["sub", "second"]) { root in
                guard let cycle = CompletionCycle(text: "s", showHidden: false, base: root) else {
                    Harness.expect(false, "a bare word completes against the base")
                    return
                }
                Harness.expectEqual(cycle.candidates, ["second/", "sub/"], "both, in order")
                Harness.expectEqual(cycle.text, "second/", "and no path is invented in front")
            }
        }
    }
}
