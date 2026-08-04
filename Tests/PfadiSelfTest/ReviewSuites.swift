import Foundation
import PfadiCore

/// Regressions for what the first review round found. Two of the four were
/// invisible from the outside, which is exactly why they get tests.
enum ReviewSuites {
    static func run() {
        realFilenames()
        relativeCompletion()
    }

    private static func realFilenames() {
        Harness.suite("listing: names keep their extension") {
            // The listing used to ask for .localizedNameKey, which returns the
            // name as Finder would draw it. With "Show all filename extensions"
            // off, that is `report`, not `report.pdf`, and a tool built around
            // typing paths must never show a name you cannot type.
            try withSandbox(["report.pdf", "archive.tar.gz", ".hidden.conf"]) { root in
                let names = try DirectoryListing.read(root, showHidden: true).map(\.name)
                Harness.expect(names.contains("report.pdf"), "single extension survives")
                Harness.expect(names.contains("archive.tar.gz"), "double extension survives")
                Harness.expect(names.contains(".hidden.conf"), "dotfile survives")
            }
        }

        Harness.suite("listing: the name is the last path component, always") {
            try withSandbox(["Documents"], directories: ["Documents"]) { root in
                let entries = try DirectoryListing.read(root, showHidden: false)
                // Never a translation: this folder is `Documents` on disk in
                // every language, and that is what you would type.
                Harness.expectEqual(
                    entries.first?.name, "Documents", "no localised display name")
                Harness.expectEqual(
                    entries.first?.name, entries.first?.url.lastPathComponent,
                    "the name matches the URL it came from")
            }
        }
    }

    private static func relativeCompletion() {
        Harness.suite("completion: a relative path completes against the current folder") {
            try withSandbox(
                ["sub", "other"], directories: ["sub", "other"]
            ) { root in
                try Data("x".utf8).write(
                    to: root.appendingPathComponent("sub/inside.txt"))

                // Without a base, a prefix that does not start with / resolved
                // to nothing and tab offered nothing, even though committing
                // the very same text navigated there without complaint.
                Harness.expectEqual(
                    PathCompletion.candidates(prefix: "", partial: "su", showHidden: false),
                    [],
                    "no base still means no candidates")

                Harness.expectEqual(
                    PathCompletion.candidates(
                        prefix: "", partial: "su", showHidden: false, base: root),
                    ["sub/"],
                    "with a base, a bare word completes")

                Harness.expectEqual(
                    PathCompletion.candidates(
                        prefix: "sub/", partial: "", showHidden: false, base: root),
                    ["inside.txt"],
                    "and so does a relative folder one level down")
            }
        }

        Harness.suite("completion: an absolute prefix ignores the base") {
            try withSandbox(["only-here.txt"]) { root in
                try withSandbox(["elsewhere.txt"]) { other in
                    Harness.expectEqual(
                        PathCompletion.candidates(
                            prefix: other.path + "/", partial: "else", showHidden: false,
                            base: root),
                        ["elsewhere.txt"],
                        "an absolute path wins over whatever the base says")
                }
            }
        }
    }
}
