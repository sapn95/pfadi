import AppKit

// Top-level code rather than @main: an @main type in a file called main.swift
// is a compile error, and this is the shortest path to a running NSApplication.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
