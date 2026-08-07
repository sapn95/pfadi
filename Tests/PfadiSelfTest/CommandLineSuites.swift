import Foundation
import PfadiCore

/// The command line, the URL scheme, and the documentation that describes them.
///
/// The old `pfadi` was two lines of shell, and every one of these checks is a
/// thing it got wrong: `--help` printed the usage of `open`, a second argument
/// vanished without a word, and a missing path produced a message about a file
/// when a folder had been asked for.
enum CommandLineSuites {
    static func run() {
        parsing()
        revealing()
        scheme()
        documentation()
    }

    private static func parsing() {
        Harness.suite("command line: nothing means the folder the shell is in") {
            try withSandbox([]) { root in
                Harness.expectEqual(
                    Invocation.parse(["pfadi"], workingDirectory: root),
                    .show([.directory(PathCompletion.directoryURL(root))]),
                    "a bare pfadi opens the working directory")
            }
        }

        Harness.suite("command line: every folder given, not only the first") {
            try withSandbox(["one", "two", "three"], directories: ["one", "two", "three"]) { root in
                // The bug in the shell version, exactly: `exec open -a … "$1"`
                // opened the first and dropped the rest without a word.
                guard
                    case .show(let targets) = Invocation.parse(
                        ["pfadi", "one", "two", "three"], workingDirectory: root)
                else {
                    Harness.expect(false, "three folders parse as something to show")
                    return
                }
                Harness.expectEqual(targets.count, 3, "all three survive")
                Harness.expectEqual(
                    targets.map(name(of:)), ["one", "two", "three"], "and in the order given")
            }
        }

        Harness.suite("command line: help and version win over anything else") {
            Harness.expectEqual(
                Invocation.parse(["pfadi", "--help"], workingDirectory: URL(fileURLWithPath: "/")),
                .help, "--help is help")
            Harness.expectEqual(
                Invocation.parse(["pfadi", "-h"], workingDirectory: URL(fileURLWithPath: "/")),
                .help, "-h too")
            Harness.expectEqual(
                Invocation.parse(
                    ["pfadi", "--version"], workingDirectory: URL(fileURLWithPath: "/")),
                .version, "--version is version")
            Harness.expectEqual(
                Invocation.parse(
                    ["pfadi", "--layout-check"], workingDirectory: URL(fileURLWithPath: "/")),
                .layoutCheck, "the checks have their own flag")
        }

        Harness.suite("command line: a path that is not there is an error, not a window") {
            try withSandbox([]) { root in
                Harness.expectEqual(
                    Invocation.parse(["pfadi", "nope"], workingDirectory: root),
                    .failed("no such file or folder: nope"),
                    "and the message says folder, not file")
            }
        }

        Harness.suite("command line: an unknown option is refused, never guessed at") {
            try withSandbox([]) { root in
                Harness.expectEqual(
                    Invocation.parse(["pfadi", "--recursive"], workingDirectory: root),
                    .failed("unknown option: --recursive"),
                    "a typo does not become a path")
                Harness.expectEqual(
                    Invocation.parse(["pfadi", "-R"], workingDirectory: root),
                    .failed("-R needs a path after it"),
                    "and a flag with nothing after it says so")
            }
        }

        Harness.suite("command line: after -- everything is a path") {
            try withSandbox(["--help"], directories: ["--help"]) { root in
                // A folder really can be called --help, and refusing to open it
                // is the kind of detail that makes a tool feel cheap.
                Harness.expectEqual(
                    Invocation.parse(["pfadi", "--", "--help"], workingDirectory: root),
                    .show([
                        .directory(
                            PathCompletion.directoryURL(root.appendingPathComponent("--help")))
                    ]),
                    "the folder wins over the flag it is named after")
            }
        }

        Harness.suite("command line: ~ and relative paths both resolve") {
            let home = FileManager.default.homeDirectoryForCurrentUser
            Harness.expectEqual(
                Invocation.parse(["pfadi", "~"], workingDirectory: URL(fileURLWithPath: "/tmp")),
                .show([.directory(PathCompletion.directoryURL(home))]),
                "~ is home wherever the shell was standing")
        }
    }

    private static func revealing() {
        Harness.suite("command line: a file is shown in its folder, not opened") {
            try withSandbox(["report.txt"]) { root in
                let file = root.appendingPathComponent("report.txt").standardizedFileURL
                Harness.expectEqual(
                    Invocation.parse(["pfadi", "report.txt"], workingDirectory: root),
                    .show([.file(file)]),
                    "a file argument means select it")
            }
        }

        Harness.suite("command line: -R points at a folder rather than opening it") {
            try withSandbox(["sub"], directories: ["sub"]) { root in
                let folder = root.appendingPathComponent("sub").standardizedFileURL
                // The distinction the file URL alone cannot carry, which is why
                // the URL scheme exists at all.
                Harness.expectEqual(
                    Invocation.parse(["pfadi", "-R", "sub"], workingDirectory: root),
                    .show([.file(folder)]),
                    "-R on a folder selects it")
                Harness.expectEqual(
                    Invocation.parse(["pfadi", "sub"], workingDirectory: root),
                    .show([.directory(PathCompletion.directoryURL(folder))]),
                    "and without -R the same folder is opened")
            }
        }

        Harness.suite("command line: reveals stay where they were typed") {
            try withSandbox(["sub", "notes.txt"], directories: ["sub"]) { root in
                // Collected separately, the reveals came out ahead of
                // everything else, so these two lines opened their tabs in the
                // same order however they were written.
                guard
                    case .show(let first) = Invocation.parse(
                        ["pfadi", "sub", "-R", "notes.txt"], workingDirectory: root),
                    case .show(let second) = Invocation.parse(
                        ["pfadi", "-R", "notes.txt", "sub"], workingDirectory: root)
                else {
                    Harness.expect(false, "both orders parse")
                    return
                }
                Harness.expectEqual(
                    first.map(name(of:)), ["sub", "notes.txt"], "folder first when written first")
                Harness.expectEqual(
                    second.map(name(of:)), ["notes.txt", "sub"], "and reveal first when it is")
            }
        }
    }

    private static func scheme() {
        Harness.suite("url scheme: a reveal survives the round trip") {
            let url = URL(fileURLWithPath: "/Users/somebody/a folder/report.txt")
            let asked = PfadiURL.reveal(url)
            Harness.expect(asked.scheme == "pfadi", "it is ours")
            Harness.expectEqual(
                PfadiURL.target(of: asked), .file(url.standardizedFileURL),
                "and comes back as the same file")
        }

        Harness.suite("url scheme: a path full of punctuation survives too") {
            // Built by hand this is a truncated path: everything from the # on
            // is a fragment, and the ? starts a query.
            let url = URL(fileURLWithPath: "/tmp/a?b#c&d=e/report v2.txt")
            Harness.expectEqual(
                PfadiURL.target(of: PfadiURL.reveal(url)),
                .file(url.standardizedFileURL),
                "? and # and & come back intact")
        }

        Harness.suite("url scheme: anything else is not ours") {
            Harness.expect(
                PfadiURL.target(of: URL(fileURLWithPath: "/tmp")) == nil,
                "a file URL is not a reveal request")
            Harness.expect(
                PfadiURL.target(of: URL(string: "pfadi://something-else?path=/tmp")!) == nil,
                "an unknown host is refused rather than guessed at")
            Harness.expect(
                PfadiURL.target(of: URL(string: "pfadi://reveal")!) == nil,
                "and a reveal with no path is not a reveal")
        }
    }

    private static func documentation() {
        Harness.suite("documentation: the man page and --help agree") {
            guard let source = repositoryFile("man/pfadi.1") else {
                Harness.expect(false, "man/pfadi.1 is where it should be")
                return
            }
            // mdoc writes an option as `Fl -reveal`, which renders as
            // `--reveal`, and the macro is as likely to be mid-line
            // (`.It Fl R , Fl -reveal`) as at the start of one. Comparing
            // against the raw source would pass on a page that spells a flag
            // out in prose and never marks it up, so the markup is undone
            // rather than searched around.
            let page =
                source
                .replacingOccurrences(of: "Fl -", with: "--")
                .replacingOccurrences(of: "Fl ", with: "-")
            // Every option the command accepts has to be documented. A flag
            // that only exists in the help text is a flag nobody finds.
            for option in ["-R", "--reveal", "--help", "--version", "--"] {
                Harness.expect(
                    page.contains(option),
                    "man/pfadi.1 mentions \(option)")
                Harness.expect(
                    Invocation.helpText.contains(option),
                    "pfadi --help mentions \(option)")
            }
        }

        Harness.suite("documentation: the version is the same in all three places") {
            guard
                let version = repositoryFile("VERSION")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            else {
                Harness.expect(false, "VERSION is where it should be")
                return
            }
            Harness.expectEqual(
                pfadiVersion, version, "PfadiCore agrees with the VERSION file")
        }
    }

    /// A file from the checkout, found relative to this source file.
    ///
    /// The tests run from wherever SwiftPM felt like putting the binary, so a
    /// path relative to the working directory would find nothing.
    private static func repositoryFile(_ path: String) -> String? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PfadiSelfTest
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the checkout
        return try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private static func name(of target: PathCompletion.Target) -> String {
        switch target {
        case .directory(let url): return url.lastPathComponent
        case .file(let url): return url.lastPathComponent
        }
    }
}
