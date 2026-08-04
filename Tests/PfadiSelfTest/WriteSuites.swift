import Foundation
import PfadiCore

/// The first operations that change the disk, so the first ones that can lose
/// somebody something.
enum WriteSuites {
    static func run() {
        names()
        folders()
        renaming()
        trashing()
    }

    private static func names() {
        Harness.suite("names: what cannot be used") {
            Harness.expectEqual(FileOperations.problem(with: ""), .empty, "nothing")
            Harness.expectEqual(FileOperations.problem(with: "   "), .empty, "only spaces")
            Harness.expectEqual(
                FileOperations.problem(with: "a/b"), .separator, "a slash is not a name")
            Harness.expectEqual(FileOperations.problem(with: "."), .reserved, "this folder")
            Harness.expectEqual(FileOperations.problem(with: ".."), .reserved, "the one above")
        }

        Harness.suite("names: what can") {
            Harness.expect(FileOperations.problem(with: "notes.txt") == nil, "an ordinary name")
            // Allowed on purpose. It will vanish from the list unless hidden
            // files are shown, which is what the person asked for.
            Harness.expect(FileOperations.problem(with: ".zshrc") == nil, "a dotfile")
            Harness.expect(FileOperations.problem(with: "a:b") == nil, "a colon, which HFS allows")
            Harness.expect(FileOperations.problem(with: "  spaced  ") == nil, "outer spaces")
        }
    }

    private static func folders() {
        Harness.suite("new folder: the name steps aside for what is there") {
            try withSandbox([]) { root in
                Harness.expectEqual(
                    FileOperations.availableName("untitled folder", in: root),
                    "untitled folder", "the first one has no number")

                try FileOperations.createFolder(named: "untitled folder", in: root)
                Harness.expectEqual(
                    FileOperations.availableName("untitled folder", in: root),
                    "untitled folder 2", "the second starts at 2, as Finder does")

                try FileOperations.createFolder(named: "untitled folder 2", in: root)
                Harness.expectEqual(
                    FileOperations.availableName("untitled folder", in: root),
                    "untitled folder 3", "and it keeps counting")
            }
        }

        Harness.suite("new folder: it is really there, and it is a folder") {
            try withSandbox([]) { root in
                let created = try FileOperations.createFolder(named: "made", in: root)
                let listed = try DirectoryListing.read(root, showHidden: false)
                Harness.expectEqual(listed.map(\.name), ["made"], "the listing sees it")
                Harness.expect(listed.first?.isDirectory == true, "as a folder")
                Harness.expect(created.hasDirectoryPath, "and the returned URL says so too")
            }
        }
    }

    private static func renaming() {
        Harness.suite("rename: moves the thing and reports where it went") {
            try withSandbox(["before.txt"]) { root in
                let original = root.appendingPathComponent("before.txt")
                let renamed = try FileOperations.rename(original, to: "after.txt")

                Harness.expectEqual(renamed.lastPathComponent, "after.txt", "the new URL")
                Harness.expect(
                    !FileManager.default.fileExists(atPath: original.path), "the old one is gone")
                Harness.expect(
                    FileManager.default.fileExists(atPath: renamed.path), "the new one is there")
            }
        }

        Harness.suite("rename: refuses to land on something that exists") {
            try withSandbox(["keep.txt", "other.txt"]) { root in
                var threw = false
                do {
                    _ = try FileOperations.rename(
                        root.appendingPathComponent("other.txt"), to: "keep.txt")
                } catch {
                    threw = true
                }
                // Replacing during a rename loses the file that was there, and
                // nobody renaming something is asking for that.
                Harness.expect(threw, "an existing destination is an error, not a replacement")
                Harness.expect(
                    FileManager.default.fileExists(
                        atPath: root.appendingPathComponent("keep.txt").path),
                    "and the file that was in the way survived")
                Harness.expect(
                    FileManager.default.fileExists(
                        atPath: root.appendingPathComponent("other.txt").path),
                    "as did the one being renamed")
            }
        }

        Harness.suite("rename: renaming to the same name does nothing") {
            try withSandbox(["same.txt"]) { root in
                let url = root.appendingPathComponent("same.txt")
                let result = try FileOperations.rename(url, to: "same.txt")
                Harness.expectEqual(result.path, url.path, "no move, no error")
                Harness.expect(FileManager.default.fileExists(atPath: url.path), "still there")
            }
        }
    }

    private static func trashing() {
        Harness.suite("trash: the file leaves, and says where it went") {
            try withSandbox(["doomed.txt"]) { root in
                let url = root.appendingPathComponent("doomed.txt")
                let trashed = try FileOperations.trash(url)

                Harness.expect(
                    !FileManager.default.fileExists(atPath: url.path), "gone from the folder")
                guard let trashed else {
                    Harness.expect(false, "and it reported where it landed")
                    return
                }
                Harness.expect(
                    FileManager.default.fileExists(atPath: trashed.path),
                    "and it is really at that address")

                // Undo is exactly this move, in reverse.
                try FileManager.default.moveItem(at: trashed, to: url)
                Harness.expect(
                    FileManager.default.fileExists(atPath: url.path), "putting it back works")
            }
        }
    }
}
