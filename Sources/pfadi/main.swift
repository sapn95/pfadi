import AppKit

// Top-level code rather than @main: an @main type in a file called main.swift
// is a compile error, and this is the shortest path to a running NSApplication.
let application = NSApplication.shared

// Before anything is shown: build the window off-screen, measure it, and say
// whether the layout put anything somewhere useless. CI runs this.
if CommandLine.arguments.contains("--layout-check") {
    application.setActivationPolicy(.accessory)
    LayoutCheck.run()
}

let delegate = AppDelegate()

// `pfadi ~/git` from a shell. Launching through LaunchServices delivers the
// folder to application(_:open:) instead, so this is the direct-execution path
// that the Homebrew shim and `swift run` take.
if let argument = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
    delegate.openOnLaunch(URL(fileURLWithPath: (argument as NSString).expandingTildeInPath))
}

application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
