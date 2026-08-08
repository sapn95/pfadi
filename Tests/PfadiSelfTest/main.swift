import Foundation
import PfadiCore

Harness.suite("listing: directories sort before files") {
    try withSandbox(["b.txt", "a-folder", "a.txt"], directories: ["a-folder"]) { root in
        let names = try DirectoryListing.read(root, showHidden: false).map(\.name)
        Harness.expectEqual(names, ["a-folder", "a.txt", "b.txt"], "folder first, then by name")
    }
}

Harness.suite("listing: names sort the way a person counts") {
    try withSandbox(["img10.png", "img2.png", "img1.png"]) { root in
        let names = try DirectoryListing.read(root, showHidden: false).map(\.name)
        Harness.expectEqual(names, ["img1.png", "img2.png", "img10.png"], "img2 before img10")
    }
}

Harness.suite("listing: hidden entries appear only when asked for") {
    try withSandbox([".secret", "visible.txt"]) { root in
        let without = try DirectoryListing.read(root, showHidden: false).map(\.name)
        Harness.expectEqual(without, ["visible.txt"], "dotfile stays out by default")

        let with = try DirectoryListing.read(root, showHidden: true).map(\.name)
        Harness.expect(with.contains(".secret"), "dotfile shows when asked for")
    }
}

Harness.suite("listing: a missing directory throws") {
    let missing = URL(fileURLWithPath: "/nope-\(UUID().uuidString)")
    var threw = false
    do {
        _ = try DirectoryListing.read(missing, showHidden: false)
    } catch {
        threw = true
    }
    Harness.expect(threw, "an unreadable path is an error, not an empty list")
}

Harness.suite("completion: narrows to the typed prefix") {
    try withSandbox(
        ["berndeutsch", "berlin.txt", "zurich.txt"], directories: ["berndeutsch"]
    ) { root in
        let candidates = PathCompletion.candidates(
            prefix: root.path + "/", partial: "ber", showHidden: false)
        // A directory keeps its slash so a second tab can carry on into it.
        Harness.expectEqual(
            candidates, ["berlin.txt", "berndeutsch/"], "only the ber* entries, folder marked")
    }
}

Harness.suite("completion: dotfiles stay out until a dot is typed") {
    try withSandbox([".zshrc", "readme.md"]) { root in
        Harness.expectEqual(
            PathCompletion.candidates(prefix: root.path + "/", partial: "", showHidden: false),
            ["readme.md"],
            "empty prefix hides dotfiles")
        Harness.expectEqual(
            PathCompletion.candidates(prefix: root.path + "/", partial: ".z", showHidden: false),
            [".zshrc"],
            "typing a dot opts back in")
    }
}

Harness.suite("resolve: tilde, relative, absolute, nonsense") {
    let home = FileManager.default.homeDirectoryForCurrentUser
    Harness.expectEqual(
        PathCompletion.resolveDirectory("~")?.path, home.path, "~ is home")

    try withSandbox(["note.txt"]) { root in
        let file = root.appendingPathComponent("note.txt").standardizedFileURL
        Harness.expectEqual(
            PathCompletion.resolve("note.txt", relativeTo: root), .file(file),
            "a relative file resolves against the current directory")
        Harness.expectEqual(
            PathCompletion.resolve(root.path, relativeTo: root),
            .directory(PathCompletion.directoryURL(root)),
            "an absolute directory resolves to itself")
        Harness.expect(
            PathCompletion.resolve("does-not-exist", relativeTo: root) == nil,
            "a path that is not there resolves to nothing")
        Harness.expect(
            PathCompletion.resolve("   ", relativeTo: root) == nil,
            "whitespace is not a path")
    }
}

Harness.suite("resolve: a directory always comes back in one spelling") {
    try withSandbox([]) { root in
        // The bug this guards, exactly as it happened: a URL built for a path
        // that does not exist yet gets no trailing slash, the same path read
        // back later gets one, and the two compare unequal forever after.
        let plannedAhead = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: plannedAhead, withIntermediateDirectories: true)
        let readBack = URL(fileURLWithPath: plannedAhead.path)

        Harness.expect(plannedAhead != readBack, "the raw Foundation URLs really are unequal")
        Harness.expectEqual(
            PathCompletion.directoryURL(plannedAhead),
            PathCompletion.directoryURL(readBack),
            "both spellings normalise to the same URL")
        Harness.expect(
            PathCompletion.directoryURL(plannedAhead).hasDirectoryPath,
            "a directory URL keeps its trailing slash")
    }
}

P1Suites.run()
ReviewSuites.run()
CycleSuites.run()

Harness.suite("root: the top has no parent, so it has no siblings") {
    // The rule the path bar leans on: clicking the leftmost folder cannot
    // offer a menu of what is beside it, because nothing is.
    Harness.expect(PathCompletion.isRoot(URL(fileURLWithPath: "/")), "/ is the top")
    Harness.expect(
        !PathCompletion.isRoot(URL(fileURLWithPath: "/Users")), "/Users is not")
    Harness.expect(
        !PathCompletion.isRoot(FileManager.default.homeDirectoryForCurrentUser),
        "and neither is home, however much it feels like it")
}
PreferenceSuites.run()
PreferenceSuites.runRemaining()
PreferenceSuites.runUpgrade()
PreferenceSuites.runAppearance()
SortingSuites.run()
FavouriteSuites.run()
WriteSuites.run()
WriteSuites.runCreating()
WriteSuites.runIconCache()
HistorySuites.run()
InfoSuites.run()
ShareSuites.run()
ShareSuites.runTitles()
ShareSuites.runEscaping()
TransferSuites.run()
TransferSuites.runMessages()
CommandLineSuites.run()
FuzzySuites.run()
FolderSizeSuites.run()
FolderSizeSuites.runIncomplete()
DefaultHandlerSuites.run()
OrderAndTrashSuites.run()
OrderAndTrashSuites.runColumns()

Harness.finish()
