import AppKit
import CoreServices
import Foundation
import PfadiCore
import UniformTypeIdentifiers

/// `pfadi-default` — put pfadi where Finder is, as far as macOS allows, and say
/// exactly where that stops.
///
/// The honest version of "replace Finder". Some of it works, some of it macOS
/// refuses outright, and the difference is measured here at run time rather
/// than assumed: every claim this tool makes about what the system will accept
/// comes from having just asked it.
///
/// There are four separate mechanisms, and they are separate because they fail
/// separately:
///
///   1. `NSFileViewer`, a global preference. This is the one that matters:
///      "Reveal in Finder" in any other application goes to pfadi. Proven.
///   2. A shell function, so `open .` in a terminal goes to pfadi.
///   3. A launcher in ~/Applications, so Spotlight can find it.
///   4. LaunchServices content types. `public.volume` is handed over;
///      `public.folder` is refused by the API and ignored when written to the
///      preference file directly. Double-clicking a folder in Finder stays
///      Finder's, and no amount of asking changes that.

let pfadiBundleID = "io.github.sapn95.pfadi"
let finderBundleID = "com.apple.finder"

// MARK: - What the system will and will not give up

/// A content type somebody might want pfadi to own.
struct Claim {
    let type: UTType
    let what: String

    static let all = [
        Claim(type: .folder, what: "folders"),
        Claim(type: .directory, what: "directories"),
        Claim(type: .volume, what: "volumes"),
    ]

    var currentHandler: String? {
        LSCopyDefaultRoleHandlerForContentType(type.identifier as CFString, .all)?
            .takeRetainedValue() as String?
    }

    /// Asks through `NSWorkspace`, which is the interface macOS has had since
    /// 12 and the one `LSSetDefaultRoleHandlerForContentType` was deprecated
    /// in favour of.
    ///
    /// It matters which one is asked, because a refusal from a deprecated
    /// function is a weaker claim than a refusal from the current one. It is
    /// the same refusal: both come back with `paramErr` for a folder, the
    /// newer one wrapped in `NSCocoaErrorDomain 256`. The old call is kept
    /// underneath only for the status code, which the wrapper hides and which
    /// is the part worth printing.
    func setHandler(at application: URL) -> Outcome {
        var failure: (any Error)?
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.setDefaultApplication(at: application, toOpen: type) { error in
            failure = error
            done.signal()
        }
        // Bounded, because a command that hangs on a preference is worse than
        // one that reports it could not set it.
        guard done.wait(timeout: .now() + 10) == .success else {
            return .failed("the system did not answer")
        }
        guard let failure else { return .done }

        let status = Self.underlyingStatus(of: failure)
        if status == DefaultHandler.refusedByLaunchServices {
            return .blocked
        }
        return .failed(
            status.map { "OSStatus \($0)" } ?? failure.localizedDescription)
    }

    /// The OSStatus underneath a Cocoa error, when there is one.
    ///
    /// `NSCocoaErrorDomain 256` says nothing on its own. The number that says
    /// what happened is in the error it wraps.
    private static func underlyingStatus(of error: any Error) -> OSStatus? {
        let outer = error as NSError
        if outer.domain == NSOSStatusErrorDomain { return OSStatus(outer.code) }
        guard let inner = outer.userInfo[NSUnderlyingErrorKey] as? NSError,
            inner.domain == NSOSStatusErrorDomain
        else { return nil }
        return OSStatus(inner.code)
    }

    enum Outcome {
        case done
        /// macOS will not reassign this type, whichever interface asks.
        case blocked
        case failed(String)

        var describedByPfadi: String {
            switch self {
            case .done: return "done"
            case .blocked: return "blocked by macOS"
            case .failed(let why): return "failed, \(why)"
            }
        }

        var isBlocked: Bool {
            if case .blocked = self { return true }
            return false
        }
    }
}

// MARK: - The global file viewer

/// Who AppKit currently thinks "Finder" is.
func fileViewer() -> String? {
    CFPreferencesCopyValue(
        DefaultHandler.fileViewerKey as CFString,
        kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
    ) as? String
}

/// Sets, or with nil clears, the global file viewer.
///
/// Written through CFPreferences rather than by editing
/// ~/Library/Preferences/.GlobalPreferences.plist: the file is cached by
/// cfprefsd, and a process that writes it behind cfprefsd's back has its change
/// overwritten the next time anything else touches the domain.
@discardableResult
func setFileViewer(_ bundleID: String?) -> Bool {
    CFPreferencesSetValue(
        DefaultHandler.fileViewerKey as CFString,
        bundleID as CFPropertyList?,
        kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    return CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
}

// MARK: - The LaunchServices handler list

func launchServiceHandlers() -> [[String: Any]] {
    CFPreferencesCopyAppValue(
        DefaultHandler.handlersKey as CFString,
        DefaultHandler.launchServicesDomain as CFString
    ) as? [[String: Any]] ?? []
}

@discardableResult
func setLaunchServiceHandlers(_ handlers: [[String: Any]]) -> Bool {
    CFPreferencesSetAppValue(
        DefaultHandler.handlersKey as CFString,
        handlers as CFPropertyList,
        DefaultHandler.launchServicesDomain as CFString)
    return CFPreferencesAppSynchronize(DefaultHandler.launchServicesDomain as CFString)
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
        return DefaultHandler.shellQuoted(candidate)
    }
    return findBundle().map { "/usr/bin/open -a \(DefaultHandler.shellQuoted($0.path))" } ?? "pfadi"
}

// MARK: - The shell function

func profileURL() -> URL {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let name = shell.hasSuffix("bash") ? ".bash_profile" : ".zshrc"
    return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(name)
}

func profileHasBlock() -> Bool {
    (try? String(contentsOf: profileURL(), encoding: .utf8))?
        .contains(DefaultHandler.markerStart) ?? false
}

func writeShellBlock() throws {
    let url = profileURL()
    var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    text = DefaultHandler.removingBlock(from: text)
    if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
    text += "\n" + DefaultHandler.shellBlock(command: launchCommand()) + "\n"
    try text.write(to: url, atomically: true, encoding: .utf8)
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

/// Whether what is at the launcher path is one of ours.
///
/// Somebody may have a real Pfadi.app there, or something else entirely under
/// that name. Removing it because it is in the way would be this tool deleting
/// an application it did not put there.
func launcherIsOurs() -> Bool {
    let plist = launcherURL().appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: plist),
        let parsed = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any],
        let identifier = parsed["CFBundleIdentifier"] as? String
    else { return false }
    return identifier == "io.github.sapn95.pfadi.launcher"
}

struct NotOurs: LocalizedError {
    let path: String
    var errorDescription: String? {
        "\(path) is already something else. Move it aside and try again."
    }
}

func writeLauncher(iconFrom bundle: URL?) throws {
    let root = launcherURL()
    let manager = FileManager.default

    if manager.fileExists(atPath: root.path) {
        guard launcherIsOurs() else { throw NotOurs(path: root.path) }
        try manager.removeItem(at: root)
    }
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

// MARK: - Printing

func row(_ label: String, _ value: String) {
    print("  \(label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(value)")
}

// MARK: - Commands

func status() {
    print("pfadi:    \(findBundle()?.path ?? "not found")")
    print("command:  \(launchCommand())")
    let launcher = FileManager.default.fileExists(atPath: launcherURL().path)
    print("launcher: \(launcher ? launcherURL().path : "not installed")")
    print("shell:    \(profileURL().path), \(profileHasBlock() ? "installed" : "not installed")")

    let viewer = fileViewer()
    print(
        "viewer:   \(viewer ?? "com.apple.finder (unset)")"
            + (viewer == pfadiBundleID ? "  <- pfadi" : ""))

    print("")
    print("Reveal in Finder, from any other application:")
    print(
        viewer == pfadiBundleID
            ? "  goes to pfadi"
            : "  goes to Finder")

    print("")
    print("What opens what, as LaunchServices has it now:")
    for claim in Claim.all {
        let handler = claim.currentHandler ?? "nothing"
        row(claim.what, handler + (handler == pfadiBundleID ? "  <- pfadi" : ""))
    }

    // What the preference file says, when that differs from what LaunchServices
    // will admit to. The gap is the whole story for folders, so it is reported
    // rather than hidden.
    let written = DefaultHandler.handler(in: launchServiceHandlers(), for: "public.folder")
    if let written, written != Claim.all[0].currentHandler {
        print("")
        print("  the preference file asks for \(written) on folders,")
        print("  and LaunchServices is ignoring it. See `man pfadi-default`.")
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

    // The one that actually replaces Finder for something people do all day.
    setFileViewer(pfadiBundleID)
    let viewerTook = fileViewer() == pfadiBundleID
    print(
        viewerTook
            ? "==> Reveal in Finder, from every application, now opens pfadi"
            : "==> could not set \(DefaultHandler.fileViewerKey); Reveal in Finder stays Finder's")

    setLaunchServiceHandlers(
        DefaultHandler.setting(
            launchServiceHandlers(), contentType: "public.folder", to: pfadiBundleID))
    print("==> asked the preference file for folders too")

    print("\nAsking LaunchServices to hand over what it will:")
    var refusedAny = false
    for claim in Claim.all {
        let outcome = claim.setHandler(at: bundle)
        if outcome.isBlocked { refusedAny = true }
        row(claim.what, outcome.describedByPfadi)
    }

    if refusedAny || Claim.all[0].currentHandler != pfadiBundleID {
        print(
            """

            Double-clicking a folder in Finder still opens Finder, and that
            part is not going to change.

            Asked through NSWorkspace, which is the current interface, macOS
            answers NSCocoaErrorDomain 256 wrapping paramErr. Asked through the
            deprecated LaunchServices call it answers paramErr directly. Same
            refusal from both, whatever the application declares and whatever
            rank it declares it at. Writing the handler into the preference file
            by hand is accepted and then ignored.

            Finder cannot be taken out of the Dock either, short of turning off
            SIP and FileVault and editing the sealed system volume, which is a
            bad trade for an icon.

            What you get instead is everything above: Reveal in Finder from any
            application, `open .` in a terminal, and Spotlight.
            """)
    }
    print("\nOpen a new terminal, or run: source \(profileURL().path)")
}

func undo() throws {
    if FileManager.default.fileExists(atPath: launcherURL().path) {
        if launcherIsOurs() {
            try FileManager.default.removeItem(at: launcherURL())
            print("==> removed \(launcherURL().path)")
        } else {
            print("==> left \(launcherURL().path) alone, it is not ours")
        }
    }

    let url = profileURL()
    if let text = try? String(contentsOf: url, encoding: .utf8),
        text.contains(DefaultHandler.markerStart)
    {
        try DefaultHandler.removingBlock(from: text)
            .write(to: url, atomically: true, encoding: .utf8)
        print("==> removed the shell function from \(url.lastPathComponent)")
    } else {
        print("==> \(url.lastPathComponent) had nothing of ours in it")
    }

    // Only when it is ours. Somebody may have pointed the file viewer at a
    // different browser since, and taking that away would be this tool
    // undoing a decision it did not make.
    if fileViewer() == pfadiBundleID {
        setFileViewer(nil)
        print("==> Reveal in Finder goes back to Finder")
    } else {
        print("==> \(DefaultHandler.fileViewerKey) was not ours, left alone")
    }

    let handlers = launchServiceHandlers()
    let cleaned = DefaultHandler.removing(
        handlers, contentType: "public.folder", ownedBy: pfadiBundleID)
    if cleaned.count != handlers.count
        || DefaultHandler.handler(in: handlers, for: "public.folder") == pfadiBundleID
    {
        setLaunchServiceHandlers(cleaned)
        print("==> took the folder request back out of the preference file")
    }

    print("\nGiving the types back to Finder:")
    guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: finderBundleID)
    else {
        print("  could not find Finder, which is a sentence nobody expected to write")
        return
    }
    for claim in Claim.all where claim.currentHandler == pfadiBundleID {
        row(claim.what, claim.setHandler(at: finder).describedByPfadi)
    }
}

let usage = """
    pfadi-default — put pfadi where Finder is, as far as macOS allows.

      pfadi-default            what the system has now, changing nothing
      pfadi-default apply      the file viewer, the launcher, the shell
                               function, and every content type macOS will
                               actually hand over
      pfadi-default undo       all of it back
      pfadi-default --help     this
      pfadi-default --version  the version

    The one that matters is the file viewer: with it set, Reveal in Finder in
    every other application opens pfadi. Double-clicking a folder inside Finder
    is Finder's and stays Finder's. See `man pfadi-default`.
    """

// MARK: - Entry

let arguments = CommandLine.arguments.dropFirst()
if arguments.count > 1 {
    // Silently ignoring the rest is how `apply --dry-run` quietly applies.
    print("one command at a time: \(arguments.joined(separator: " "))")
    exit(1)
}

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
case "-h", "--help", "help":
    print(usage)
case "-v", "--version":
    print("pfadi-default \(pfadiVersion)")
default:
    print(usage)
    exit(1)
}
