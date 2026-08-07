import Foundation
import PfadiCore

/// Copying and moving: the operations that can lose somebody a folder.
enum TransferSuites {
    static func run() {
        refusals()
        planning()
        naming()
        running()
    }

    private static func refusals() {
        Harness.suite("transfer: a folder cannot go inside itself") {
            try withSandbox(["outer"], directories: ["outer"]) { root in
                let outer = root.appendingPathComponent("outer")
                let inner = outer.appendingPathComponent("inner")
                try FileManager.default.createDirectory(
                    at: inner, withIntermediateDirectories: true)

                Harness.expectEqual(
                    Transfer.check(moving: [outer], into: outer, kind: .copy),
                    .intoItself(outer.standardizedFileURL),
                    "into itself")

                // Copying a folder into its own descendant walks forever;
                // moving one detaches the branch you are standing on.
                Harness.expectEqual(
                    Transfer.check(moving: [outer], into: inner, kind: .move),
                    .intoOwnDescendant(outer.standardizedFileURL),
                    "into something inside it")
            }
        }

        Harness.suite("transfer: prefix matching is not enough") {
            // /a/bc is not inside /a/b, however much the strings suggest it.
            Harness.expect(
                !Transfer.isAncestor(
                    URL(fileURLWithPath: "/a/b"), of: URL(fileURLWithPath: "/a/bc")),
                "a longer sibling is not a child")
            Harness.expect(
                Transfer.isAncestor(
                    URL(fileURLWithPath: "/a/b"), of: URL(fileURLWithPath: "/a/b/c")),
                "but a real child is")
            Harness.expect(
                !Transfer.isAncestor(
                    URL(fileURLWithPath: "/a/b"), of: URL(fileURLWithPath: "/a/b")),
                "and a folder is not its own ancestor")
        }

        Harness.suite("transfer: the other refusals") {
            try withSandbox(["file.txt"]) { root in
                let file = root.appendingPathComponent("file.txt")
                Harness.expectEqual(
                    Transfer.check(moving: [file], into: root, kind: .move),
                    .sameFolder(file.standardizedFileURL),
                    "moving something to where it already is")
                Harness.expect(
                    Transfer.check(moving: [file], into: root, kind: .copy) == nil,
                    "but copying it there is a duplicate, which is fine")
                Harness.expectEqual(
                    Transfer.check(
                        moving: [root.appendingPathComponent("gone.txt")], into: root, kind: .copy),
                    .missing(root.appendingPathComponent("gone.txt").standardizedFileURL),
                    "and something that is not there any more")
            }
        }
    }

    private static func planning() {
        Harness.suite("transfer: a tree is flattened, hidden files included") {
            try withSandbox(["tree", "target"], directories: ["tree", "target"]) { root in
                let tree = root.appendingPathComponent("tree")
                try Data("hello".utf8).write(to: tree.appendingPathComponent("a.txt"))
                // A copy that quietly leaves out .git is not a copy.
                try Data("x".utf8).write(to: tree.appendingPathComponent(".hidden"))
                let sub = tree.appendingPathComponent("sub")
                try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
                try Data("worldly".utf8).write(to: sub.appendingPathComponent("b.txt"))

                let plan = Transfer.plan(
                    [tree], into: root.appendingPathComponent("target"), kind: .copy)

                Harness.expectEqual(plan.items.count, 5, "two folders, three files")
                Harness.expect(
                    plan.items.contains { $0.source.lastPathComponent == ".hidden" },
                    "the dotfile is in there")
                Harness.expectEqual(plan.totalBytes, 13, "5 + 1 + 7 bytes")
                Harness.expect(plan.conflicts.isEmpty, "and nothing is in the way")
            }
        }

        Harness.suite("transfer: collisions are found before anything happens") {
            try withSandbox(["a.txt", "target"], directories: ["target"]) { root in
                let target = root.appendingPathComponent("target")
                try Data("old".utf8).write(to: target.appendingPathComponent("a.txt"))

                let plan = Transfer.plan(
                    [root.appendingPathComponent("a.txt")], into: target, kind: .copy)
                Harness.expectEqual(plan.conflicts.count, 1, "one collision")
                Harness.expectEqual(
                    plan.conflicts.first?.lastPathComponent, "a.txt", "and it is named")
            }
        }
    }

    private static func naming() {
        Harness.suite("transfer: keep-both names the way Finder does") {
            try withSandbox(["report.pdf", "notes"]) { root in
                let report = root.appendingPathComponent("report.pdf")
                Harness.expectEqual(
                    Transfer.keepBothName(for: report, in: root), "report copy.pdf",
                    "the extension stays at the end")

                try Data("x".utf8).write(to: root.appendingPathComponent("report copy.pdf"))
                Harness.expectEqual(
                    Transfer.keepBothName(for: report, in: root), "report copy 2.pdf",
                    "and then it counts")

                Harness.expectEqual(
                    Transfer.keepBothName(for: root.appendingPathComponent("notes"), in: root),
                    "notes copy", "something with no extension keeps none")
            }
        }
    }

    private static func running() {
        Harness.suite("transfer: a copy really copies, and leaves the original") {
            try withSandbox(["source", "target"], directories: ["source", "target"]) { root in
                let source = root.appendingPathComponent("source")
                let target = root.appendingPathComponent("target")
                try Data("contents".utf8).write(to: source.appendingPathComponent("file.txt"))

                let plan = Transfer.plan([source], into: target, kind: .copy)
                let outcome = runSynchronously(plan)

                Harness.expect(!outcome.cancelled, "it finished")
                Harness.expect(outcome.failed.isEmpty, "with nothing failing")

                let copied = target.appendingPathComponent("source/file.txt")
                Harness.expectEqual(
                    try? String(contentsOf: copied, encoding: .utf8), "contents",
                    "the bytes arrived")
                Harness.expect(
                    FileManager.default.fileExists(
                        atPath: source.appendingPathComponent("file.txt").path),
                    "and the original is still there")
            }
        }

        Harness.suite("transfer: a move takes the original with it") {
            try withSandbox(["source", "target"], directories: ["source", "target"]) { root in
                let source = root.appendingPathComponent("source")
                let target = root.appendingPathComponent("target")
                try Data("moving".utf8).write(to: source.appendingPathComponent("file.txt"))

                let outcome = runSynchronously(Transfer.plan([source], into: target, kind: .move))
                Harness.expect(outcome.failed.isEmpty, "nothing failed")
                Harness.expect(
                    FileManager.default.fileExists(
                        atPath: target.appendingPathComponent("source/file.txt").path),
                    "it is at the destination")
                Harness.expect(
                    !FileManager.default.fileExists(
                        atPath: source.appendingPathComponent("file.txt").path),
                    "and gone from where it was")
            }
        }

        Harness.suite("transfer: moving a folder takes the folder, not just its files") {
            try withSandbox(["source", "target"], directories: ["source", "target"]) { root in
                let source = root.appendingPathComponent("source")
                let target = root.appendingPathComponent("target")
                let nested = source.appendingPathComponent("deep")
                try FileManager.default.createDirectory(
                    at: nested, withIntermediateDirectories: true)
                try Data("x".utf8).write(to: nested.appendingPathComponent("file.txt"))

                let outcome = runSynchronously(Transfer.plan([source], into: target, kind: .move))
                Harness.expect(outcome.failed.isEmpty, "nothing failed")

                Harness.expect(
                    FileManager.default.fileExists(
                        atPath: target.appendingPathComponent("source/deep/file.txt").path),
                    "the file arrived")
                // The bug: files were moved out one at a time and the folders
                // they came from were left behind, empty.
                Harness.expect(
                    !FileManager.default.fileExists(atPath: nested.path),
                    "the folder it came from went with it")
                Harness.expect(
                    !FileManager.default.fileExists(atPath: source.path),
                    "and so did the one above that")
                Harness.expectEqual(
                    outcome.emptiedSources.count, 2, "both are reported, so undo can put them back")
            }
        }

        Harness.suite("transfer: a move can be undone") {
            try withSandbox(["source", "target"], directories: ["source", "target"]) { root in
                let source = root.appendingPathComponent("source")
                let target = root.appendingPathComponent("target")
                try Data("precious".utf8).write(to: source.appendingPathComponent("file.txt"))

                let outcome = runSynchronously(Transfer.plan([source], into: target, kind: .move))

                // Undoing a move used to trash everything first and then try to
                // move it back out of the trash, which always failed.
                for folder in outcome.emptiedSources.reversed() {
                    try? FileManager.default.createDirectory(
                        at: folder, withIntermediateDirectories: true)
                }
                for move in outcome.moved {
                    try? FileManager.default.moveItem(at: move.to, to: move.from)
                }

                Harness.expectEqual(
                    try? String(
                        contentsOf: source.appendingPathComponent("file.txt"), encoding: .utf8),
                    "precious",
                    "the file is back where it started, not in the trash")
            }
        }

        Harness.suite("transfer: replacing trashes rather than destroys") {
            try withSandbox(["a.txt", "target"], directories: ["target"]) { root in
                let target = root.appendingPathComponent("target")
                let existing = target.appendingPathComponent("a.txt")
                try Data("old".utf8).write(to: existing)
                try Data("new".utf8).write(to: root.appendingPathComponent("a.txt"))

                let plan = Transfer.plan(
                    [root.appendingPathComponent("a.txt")], into: target, kind: .copy)
                let outcome = runSynchronously(
                    plan, resolutions: [existing: .replace])

                Harness.expectEqual(
                    try? String(contentsOf: existing, encoding: .utf8), "new",
                    "the new one is in place")
                Harness.expectEqual(
                    outcome.displaced.count, 1, "and the old one was displaced, not deleted")

                if let displaced = outcome.displaced.first {
                    Harness.expectEqual(
                        try? String(contentsOf: displaced.inTrash, encoding: .utf8), "old",
                        "it is intact in the trash, which is what makes this undoable")
                    try? FileManager.default.removeItem(at: displaced.inTrash)
                }
            }
        }

        Harness.suite("transfer: replacing a file with itself keeps both instead") {
            try withSandbox(["only.txt"]) { root in
                let file = root.appendingPathComponent("only.txt")
                let plan = Transfer.plan([file], into: root, kind: .copy)
                // Duplicating into the same folder collides with the original.
                // Replace would trash the source and then copy from the trash.
                let outcome = runSynchronously(plan, resolutions: [file: .replace])

                Harness.expect(outcome.failed.isEmpty, "it did not fail")
                Harness.expect(
                    FileManager.default.fileExists(atPath: file.path),
                    "the original is still there")
                Harness.expect(
                    FileManager.default.fileExists(
                        atPath: root.appendingPathComponent("only copy.txt").path),
                    "and there is a copy next to it")
            }
        }

        Harness.suite("transfer: skipping a folder skips what is inside it") {
            try withSandbox(["source", "target"], directories: ["source", "target"]) { root in
                let source = root.appendingPathComponent("source")
                let target = root.appendingPathComponent("target")
                try Data("x".utf8).write(to: source.appendingPathComponent("inside.txt"))
                try FileManager.default.createDirectory(
                    at: target.appendingPathComponent("source"), withIntermediateDirectories: true)

                let plan = Transfer.plan([source], into: target, kind: .copy)
                let outcome = runSynchronously(
                    plan, resolutions: [target.appendingPathComponent("source"): .skip])

                // Half a folder is worse than none of it.
                Harness.expect(
                    !FileManager.default.fileExists(
                        atPath: target.appendingPathComponent("source/inside.txt").path),
                    "the contents were skipped with the folder")
                Harness.expectEqual(outcome.skipped, 2, "both the folder and its file")
            }
        }
    }

    /// The runner is asynchronous by design. The tests are not.
    private static func runSynchronously(
        _ plan: Transfer.Plan,
        resolutions: [URL: Transfer.Resolution] = [:]
    ) -> TransferRunner.Outcome {
        let runner = TransferRunner()
        let done = DispatchSemaphore(value: 0)

        let box = OutcomeBox()
        runner.run(plan, resolutions: resolutions) { _ in
        } completion: { outcome in
            box.value = outcome
            done.signal()
        }

        // The runner reports on the main queue, so the main queue has to keep
        // turning while we wait for it. Blocking on the semaphore alone would
        // deadlock: the thing being waited for needs this thread to run.
        while box.value == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        _ = done.wait(timeout: .now())
        return box.value!
    }
}

/// Somewhere for the completion handler to leave its answer that does not
/// involve mutating a captured var across a queue boundary.
private final class OutcomeBox: @unchecked Sendable {
    var value: TransferRunner.Outcome?
}

extension TransferSuites {
    /// The parts of a refusal a person actually reads.
    static func runMessages() {
        Harness.suite("transfer: a refusal says which file and why") {
            let folder = URL(fileURLWithPath: "/tmp/project")
            // Each one names the item, because "that is not allowed" about an
            // unnamed file in a selection of twenty is not an explanation.
            Harness.expectEqual(
                Transfer.Refusal.intoItself(folder).message,
                "project cannot be put inside itself", "into itself")
            Harness.expectEqual(
                Transfer.Refusal.intoOwnDescendant(folder).message,
                "project cannot be moved into a folder inside it", "into its own descendant")
            Harness.expectEqual(
                Transfer.Refusal.sameFolder(folder).message,
                "that is already where it is", "into where it already is")
            Harness.expectEqual(
                Transfer.Refusal.missing(folder).message,
                "project is no longer there", "and one that has since gone")
        }

        Harness.suite("transfer: an empty plan says so") {
            try withSandbox([]) { root in
                // What the controller checks before starting a progress bar
                // for nothing.
                let plan = Transfer.plan([], into: root, kind: .copy)
                Harness.expect(plan.isEmpty, "nothing to copy is an empty plan")

                try Data("x".utf8).write(to: root.appendingPathComponent("one.txt"))
                Harness.expect(
                    !Transfer.plan(
                        [root.appendingPathComponent("one.txt")], into: root, kind: .copy
                    ).isEmpty,
                    "and one file is not")
            }
        }
    }
}
