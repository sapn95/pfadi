import AppKit
import PfadiCore

// Top-level code rather than @main: an @main type in a file called main.swift
// is a compile error, and this is the shortest path to a running NSApplication.
let application = NSApplication.shared

// LaunchServices starts this bundle with no arguments and sends what was asked
// for as an open event instead. Parsing an empty command line would answer "the
// current folder", and the current folder of a process LaunchServices started
// is `/` — which is how `pfadi ~/git ~/Downloads` opened three tabs, one of
// them the root of the disk that nobody had asked for.
let launchedBare = CommandLine.arguments.count == 1
let invocation =
    launchedBare
    ? Invocation.show([])
    : Invocation.parse(
        CommandLine.arguments,
        workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

// Before anything is shown: build the window off-screen, measure it, and say
// whether the layout put anything somewhere useless. CI runs this.
if case .layoutCheck = invocation {
    application.setActivationPolicy(.accessory)
    LayoutCheck.run()
}

let delegate = AppDelegate()

// The same parser the `pfadi` command uses, so `pfadi ~/git` and this binary
// run with the same argument cannot disagree about what was meant. Launching
// through LaunchServices delivers URLs to application(_:open:) instead; this is
// the direct-execution path that `swift run` and a bare binary take.
switch invocation {
case .help:
    print(Invocation.helpText)
    exit(0)
case .version:
    print("pfadi \(pfadiVersion)")
    exit(0)
case .failed(let message):
    FileHandle.standardError.write(Data("pfadi: \(message)\n".utf8))
    exit(1)
case .show(let targets):
    delegate.openOnLaunch(targets)
case .layoutCheck:
    break  // handled above, before any of this was built
}

application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
