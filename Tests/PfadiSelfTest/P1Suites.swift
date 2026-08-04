import Foundation
import PfadiCore

/// Suites for the four features added after the first browser: watching,
/// type-ahead, the start folder, and nothing else that writes to disk.
enum P1Suites {
    static func run() {
        typeAhead()
        startDirectory()
        watcher()
    }

    private static func typeAhead() {
        let names = ["Applications", "terraform-aws-core", "terragrunt", "tests", "zsh"]

        Harness.suite("type-ahead: a prefix finds the first match") {
            Harness.expectEqual(
                TypeAhead.index(matching: "terra", in: names, current: nil), 1,
                "terra lands on terraform-aws-core")
            Harness.expectEqual(
                TypeAhead.index(matching: "terrag", in: names, current: nil), 2,
                "one more letter refines rather than steps")
        }

        Harness.suite("type-ahead: a single letter cycles, a longer prefix does not") {
            Harness.expectEqual(
                TypeAhead.index(matching: "t", in: names, current: nil), 1, "first t")
            Harness.expectEqual(
                TypeAhead.index(matching: "t", in: names, current: 1), 2, "next t")
            Harness.expectEqual(
                TypeAhead.index(matching: "t", in: names, current: 3), 1,
                "past the last t it wraps around")
            Harness.expectEqual(
                TypeAhead.index(matching: "te", in: names, current: 3), 1,
                "a two-letter prefix always starts from the top")
        }

        Harness.suite("type-ahead: case and diacritics do not matter") {
            Harness.expectEqual(
                TypeAhead.index(matching: "APPL", in: names, current: nil), 0, "case ignored")
            Harness.expectEqual(
                TypeAhead.index(matching: "uber", in: ["Über", "unrelated"], current: nil), 0,
                "uber finds Über")
        }

        Harness.suite("type-ahead: no match and no input") {
            Harness.expect(
                TypeAhead.index(matching: "qqq", in: names, current: nil) == nil, "no match")
            Harness.expect(
                TypeAhead.index(matching: "", in: names, current: nil) == nil, "empty prefix")
            Harness.expect(
                TypeAhead.index(matching: "a", in: [], current: nil) == nil, "empty list")
        }

        Harness.suite("type-ahead: the buffer expires") {
            Harness.expectEqual(
                TypeAhead.buffer("te", appending: "r", lastKeystroke: 100, now: 100.3), "ter",
                "a quick keystroke continues the word")
            Harness.expectEqual(
                TypeAhead.buffer("te", appending: "r", lastKeystroke: 100, now: 102), "r",
                "a slow one starts over")
        }
    }

    private static func startDirectory() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let root = URL(fileURLWithPath: "/")

        Harness.suite("start folder: the most recent instruction wins") {
            try withSandbox([]) { sandbox in
                Harness.expectEqual(
                    StartDirectory.choose(
                        explicit: sandbox, workingDirectory: root, remembered: home.path,
                        home: home
                    ).path,
                    sandbox.path,
                    "an explicit folder beats everything")

                Harness.expectEqual(
                    StartDirectory.choose(
                        explicit: nil, workingDirectory: sandbox, remembered: home.path, home: home
                    ).path,
                    sandbox.path,
                    "the shell's directory beats what was remembered")

                Harness.expectEqual(
                    StartDirectory.choose(
                        explicit: nil, workingDirectory: root, remembered: sandbox.path, home: home
                    ).path,
                    sandbox.path,
                    "with no instruction, the remembered folder wins")
            }
        }

        Harness.suite("start folder: falls back when the memory is stale") {
            Harness.expectEqual(
                StartDirectory.choose(
                    explicit: nil, workingDirectory: root,
                    remembered: "/gone-\(UUID().uuidString)", home: home
                ).path,
                home.path,
                "a folder that no longer exists falls back to home")

            Harness.expectEqual(
                StartDirectory.choose(
                    explicit: nil, workingDirectory: root, remembered: nil, home: home
                ).path,
                home.path,
                "nothing remembered falls back to home")
        }
    }

    private static func watcher() {
        Harness.suite("watcher: a write in the folder arrives without asking") {
            try withSandbox([]) { root in
                // A private queue, because the self-test has no run loop to
                // deliver anything on the main one.
                let queue = DispatchQueue(label: "pfadi.selftest.watcher")
                let fired = DispatchSemaphore(value: 0)

                let watcher = DirectoryWatcher(
                    url: root, queue: queue, debounce: .milliseconds(50)
                ) {
                    fired.signal()
                }
                Harness.expect(watcher.start(), "the watcher attaches to the folder")

                try Data("x".utf8).write(to: root.appendingPathComponent("appeared.txt"))
                Harness.expect(
                    fired.wait(timeout: .now() + 5) == .success,
                    "a new file notifies within five seconds")

                watcher.stop()
            }
        }

        Harness.suite("watcher: a folder that is not there fails quietly") {
            let missing = URL(fileURLWithPath: "/nope-\(UUID().uuidString)")
            let watcher = DirectoryWatcher(url: missing) {}
            Harness.expect(!watcher.start(), "start reports false rather than throwing")
        }
    }
}
