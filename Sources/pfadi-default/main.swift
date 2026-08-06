import AppKit
import CoreServices
import Foundation

/// `pfadi-default` — put pfadi where Finder is, as far as macOS allows, and say
/// exactly where that stops.
///
/// The honest version of "replace Finder". Some of it works, some of it macOS
/// refuses outright, and the difference is measured here at run time rather
/// than assumed: every claim this tool makes about what the system will accept
/// comes from having just asked it.

// MARK: - What the system will and will not give up

/// A content type somebody might want pfadi to own.
struct Claim {
    let type: String
    let what: String

    static let all = [
        Claim(type: "public.folder", what: "folders"),
        Claim(type: "public.directory", what: "directories"),
        Claim(type: "public.volume", what: "volumes"),
    ]

    var currentHandler: String? {
        LSCopyDefaultRoleHandlerForContentType(type as CFString, .all)?
            .takeRetainedValue() as String?
    }

    func setHandler(_ bundleID: String) -> OSStatus {
        LSSetDefaultRoleHandlerForContentType(type as CFString, .all, bundleID as CFString)
    }
}

let pfadiBundleID = "io.github.sapn95.pfadi"
let finderBundleID = "com.apple.finder"

/// paramErr. What LaunchServices returns for a type it will not reassign,
/// which on this system is every type that means "a folder".
let refused: OSStatus = -50

func describe(_ status: OSStatus) -> String {
    switch status {
    case 0: return "done"
    case refused: return "refused by macOS"
    default: return "failed, OSStatus \(status)"
    }
}

// MARK: - Finding the application

func findBundle() -> URL? {
    if let override = ProcessInfo.processInfo.environment["PFADI_APP"] {
        return URL(fileURLWithPath: override)
    }
    if let byID = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pfadiBundleID) {
        return byID
    }
    let candidates = [
        "/opt/homebrew/opt/pfadi/Pfadi.app",
        "/usr/local/opt/pfadi/Pfadi.app",
        "/Applications/Pfadi.app",
        NSHomeDirectory() + "/Applications/Pfadi.app",
        FileManager.default.currentDirectoryPath + "/build/Pfadi.app",
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0) }
        .map { URL(fileURLWithPath: $0) }
}

/// The command, not the bundle: it is what stays correct across an upgrade,
/// because brew rewrites it to point at whatever it just installed.
func launchCommand() -> String {
    for candidate in ["/opt/homebrew/bin/pfadi", "/usr/local/bin/pfadi"]
    where FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
    }
    return findBundle().map { "/usr/bin/open -a \"\($0.path)\"" } ?? "pfadi"
}

// MARK: - The shell function

let markerStart = "# >>> pfadi instead of finder >>>"
let markerEnd = "# <<< pfadi instead of finder <<<"

func profileURL() -> URL {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let name = shell.hasSuffix("bash") ? ".bash_profile" : ".zshrc"
    return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(name)
}

func shellBlock() -> String {
    """
    \(markerStart)
    # `open .` and `open <folder>` go to pfadi. Everything else is untouched,
    # so `open report.pdf` still opens whatever owns a PDF.
    open() {
      if [ $# -eq 1 ] && [ -d "$1" ]; then
        command \(launchCommand()) "$1"
      else
        command open "$@"
      fi
    }
    \(markerEnd)
    """
}

func profileHasBlock() -> Bool {
    (try? String(contentsOf: profileURL(), encoding: .utf8))?.contains(markerStart) ?? false
}

func writeShellBlock() throws {
    let url = profileURL()
    var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    text = removingBlock(from: text)
    if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
    text += "\n" + shellBlock() + "\n"
    try text.write(to: url, atomically: true, encoding: .utf8)
}

func removingBlock(from text: String) -> String {
    guard let start = text.range(of: markerStart),
        let end = text.range(of: markerEnd)
    else { return text }
    var cut = text
    // Through the end of the marker line, and the newline after it.
    let upTo = text.index(end.upperBound, offsetBy: 1, limitedBy: text.endIndex) ?? end.upperBound
    cut.removeSubrange(start.lowerBound..<upTo)
    return cut
}

// MARK: - The launcher

/// A bundle in ~/Applications whose only job is to start the real one.
///
/// A symlink there is not indexed: Spotlight indexes ~/Applications but not
/// Homebrew's Cellar, and a link gives it nothing of its own to look at. A copy
/// is indexed and then goes stale the next time brew upgrades the real thing,
/// which is worse, because it keeps launching a version that is no longer
/// installed. This is neither: it holds the command, not the application.
func launcherURL() -> URL {
    URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Applications/Pfadi.app")
}

func writeLauncher(iconFrom bundle: URL?) throws {
    let root = launcherURL()
    let manager = FileManager.default
    try? manager.removeItem(at: root)
    try manager.createDirectory(
        at: root.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try manager.createDirectory(
        at: root.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)

    let script = "#!/bin/sh\nexec \(launchCommand()) \"$@\"\n"
    let executable = root.appendingPathComponent("Contents/MacOS/launch")
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    if let icon = bundle?.appendingPathComponent("Contents/Resources/Icon.icns"),
        manager.fileExists(atPath: icon.path)
    {
        try? manager.copyItem(
            at: icon, to: root.appendingPathComponent("Contents/Resources/Icon.icns"))
    }

    let plist: [String: Any] = [
        "CFBundleExecutable": "launch",
        "CFBundleIdentifier": "io.github.sapn95.pfadi.launcher",
        "CFBundleName": "pfadi",
        "CFBundleIconFile": "Icon",
        "CFBundlePackageType": "APPL",
        // An agent, so the launcher itself never appears in the Dock beside
        // the application it just started.
        "LSUIElement": true,
    ]
    let data = try PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: root.appendingPathComponent("Contents/Info.plist"))

    register(root)
}

func register(_ bundle: URL) {
    let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework"
        + "/Support/lsregister"
    guard FileManager.default.isExecutableFile(atPath: lsregister) else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: lsregister)
    process.arguments = ["-f", bundle.path]
    try? process.run()
    process.waitUntilExit()
}

// MARK: - Commands

func status() {
    print("pfadi:    \(findBundle()?.path ?? "not found")")
    print("command:  \(launchCommand())")
    print(
        "launcher: \(FileManager.default.fileExists(atPath: launcherURL().path) ? launcherURL().path : "not installed")"
    )
    print(
        "shell:    \(profileHasBlock() ? "\(profileURL().path), installed" : "\(profileURL().path), not installed")"
    )
    print("")
    print("What opens what, as the system has it now:")
    for claim in Claim.all {
        let handler = claim.currentHandler ?? "nothing"
        let mine = handler == pfadiBundleID ? "  <- pfadi" : ""
        print(
            "  \(claim.what.padding(toLength: 12, withPad: " ", startingAt: 0)) \(handler)\(mine)")
    }
}

func apply() throws {
    guard let bundle = findBundle() else {
        print("cannot find Pfadi.app. Set PFADI_APP to it and try again.")
        exit(1)
    }
    print("pfadi: \(bundle.path)\n")

    register(bundle)
    try writeLauncher(iconFrom: bundle)
    print("==> put \(launcherURL().path) where Spotlight looks")

    try writeShellBlock()
    print("==> `open .` in \(profileURL().lastPathComponent) now goes to pfadi")

    print("\nAsking LaunchServices to hand over what it will:")
    var refusedAny = false
    for claim in Claim.all {
        let status = claim.setHandler(pfadiBundleID)
        if status == refused { refusedAny = true }
        print(
            "  \(claim.what.padding(toLength: 12, withPad: " ", startingAt: 0)) \(describe(status))"
        )
    }

    if refusedAny {
        print(
            """

            macOS will not let anything but Finder be the default for a folder.
            That is not a missing feature here: LSSetDefaultRoleHandlerForContentType
            returns paramErr for public.folder whatever the application declares,
            and the same for the file:// scheme. The shell function above exists
            because of it, and Finder cannot be taken out of the Dock either.
            """)
    }
    print("\nOpen a new terminal, or run: source \(profileURL().path)")
}

func undo() throws {
    try? FileManager.default.removeItem(at: launcherURL())
    print("==> removed \(launcherURL().path)")

    let url = profileURL()
    if let text = try? String(contentsOf: url, encoding: .utf8), text.contains(markerStart) {
        try removingBlock(from: text).write(to: url, atomically: true, encoding: .utf8)
        print("==> removed the shell function from \(url.lastPathComponent)")
    } else {
        print("==> \(url.lastPathComponent) had nothing of ours in it")
    }

    print("\nGiving the types back to Finder:")
    for claim in Claim.all where claim.currentHandler == pfadiBundleID {
        let status = claim.setHandler(finderBundleID)
        print(
            "  \(claim.what.padding(toLength: 12, withPad: " ", startingAt: 0)) \(describe(status))"
        )
    }
}

// MARK: - Entry

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "apply":
    try apply()
case "undo":
    try undo()
case "status", nil:
    status()
    if arguments.first == nil {
        print("\nNothing has been changed. `pfadi-default apply` does it, `undo` puts it back.")
    }
default:
    print(
        """
        pfadi-default — put pfadi where Finder is, as far as macOS allows.

          pfadi-default            what the system has now, changing nothing
          pfadi-default apply      the launcher, the shell function, and every
                                   content type macOS will actually hand over
          pfadi-default undo       all of it back
        """)
    exit(1)
}
