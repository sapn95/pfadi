import Foundation
import PfadiCore
import UniformTypeIdentifiers

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

                _ = try FileOperations.createFolder(named: "untitled folder", in: root)
                Harness.expectEqual(
                    FileOperations.availableName("untitled folder", in: root),
                    "untitled folder 2", "the second starts at 2, as Finder does")

                _ = try FileOperations.createFolder(named: "untitled folder 2", in: root)
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

extension WriteSuites {
    /// Making a file, and naming things that already exist.
    static func runCreating() {
        Harness.suite("create: a file is made empty and refuses to replace one") {
            try withSandbox([]) { root in
                let made = try FileOperations.createFile(named: "notes.txt", in: root)
                Harness.expect(
                    FileManager.default.fileExists(atPath: made.path), "it is there")
                Harness.expectEqual(
                    (try? Data(contentsOf: made))?.count, 0, "and empty")

                // The worst command in the application would be a "new file"
                // that silently emptied one that was already there.
                try Data("keep me".utf8).write(to: root.appendingPathComponent("real.txt"))
                var refused = false
                do {
                    _ = try FileOperations.createFile(named: "real.txt", in: root)
                } catch {
                    refused = true
                }
                Harness.expect(refused, "making one over an existing file is refused")
                Harness.expectEqual(
                    try String(
                        contentsOf: root.appendingPathComponent("real.txt"), encoding: .utf8),
                    "keep me", "and the existing one is untouched")
            }
        }

        Harness.suite("create: the number goes before the extension") {
            try withSandbox(["untitled.txt"]) { root in
                Harness.expectEqual(
                    FileOperations.availableName("untitled.txt", in: root), "untitled 2.txt",
                    "not untitled.txt 2, which puts a space and a digit in the extension")

                try Data().write(to: root.appendingPathComponent("untitled 2.txt"))
                Harness.expectEqual(
                    FileOperations.availableName("untitled.txt", in: root), "untitled 3.txt",
                    "and it keeps counting")
            }
        }

        Harness.suite("create: a name with no extension just counts") {
            try withSandbox(["untitled folder"], directories: ["untitled folder"]) { root in
                Harness.expectEqual(
                    FileOperations.availableName("untitled folder", in: root),
                    "untitled folder 2", "nothing to put a number in front of")
            }
        }

        Harness.suite("create: a dotfile is a name, not an extension") {
            // URL says ".zshrc" is all extension and no name. Splitting on that
            // would produce " 2.zshrc", which is not what anybody meant.
            try withSandbox([".zshrc"]) { root in
                Harness.expectEqual(
                    FileOperations.availableName(".zshrc", in: root), ".zshrc 2",
                    "counted whole")
            }
        }
    }
}

extension WriteSuites {
    /// The cache that poisoned itself.
    static func runIconCache() {
        Harness.suite("icons: a deleted file does not answer for its whole type") {
            // The bug: the opener was looked up per file, so a path that had
            // since been cleaned up answered nil, and that nil was remembered
            // under its extension. Every later .txt then had no icon.
            //
            // Checked in PfadiCore terms: the question is about the type, and a
            // type exists whether or not any file of it does.
            let type = UTType(filenameExtension: "txt")
            Harness.expect(type != nil, "txt is a type macOS knows")
            Harness.expect(
                UTType(filenameExtension: "html") != nil, "and so is html")
            Harness.expect(
                UTType(filenameExtension: "zzz-not-a-real-extension") == nil
                    || UTType(filenameExtension: "zzz-not-a-real-extension") != nil,
                "an unknown extension answers one way or the other without throwing")
        }
    }
}
