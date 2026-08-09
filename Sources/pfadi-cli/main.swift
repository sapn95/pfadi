import AppKit
import Foundation
import PfadiCore

/// `pfadi` — the command that opens the window.
///
/// This used to be two lines of shell that handed `$1` to `/usr/bin/open`. It
/// worked for the one case it was written for and was wrong about everything
/// else: `pfadi --help` printed the usage of `open`, `pfadi a b` opened `a` and
/// dropped `b` without a word, and a path that did not exist produced "The file
/// … does not exist" about a folder.
///
/// It still goes through LaunchServices rather than running the application
/// directly, and that part was right: executing the binary holds the terminal
/// until the window is closed, whereas asking LaunchServices returns at once,
/// reuses a window that is already open, and gets the Dock and the application
/// switcher right.

/// Where the application is.
///
/// By identifier first, so an upgrade is followed automatically, then the
/// places it is actually installed. `PFADI_APP` overrides everything, which is
/// what the checks and a from-source build use.
func findBundle() -> URL? {
    if let override = ProcessInfo.processInfo.environment["PFADI_APP"] {
        return URL(fileURLWithPath: override)
    }
    if let byID = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "io.github.sapn95.pfadi")
    {
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

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("pfadi: \(message)\n".utf8))
    exit(1)
}

/// Asks LaunchServices to open `urls` with the bundle, and waits only for the
/// answer, not for the window.
func open(_ urls: [URL], with bundle: URL) -> (any Error)? {
    let configuration = NSWorkspace.OpenConfiguration()
    // The window should come forward. Somebody who typed `pfadi` is looking
    // at the terminal and expects to stop looking at it.
    configuration.activates = true

    var failure: (any Error)?
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.open(urls, withApplicationAt: bundle, configuration: configuration) {
        _, error in
        failure = error
        done.signal()
    }
    // A bounded wait. Without one, a LaunchServices call that never answers
    // hangs the terminal, which is the exact thing this command exists not to
    // do. Ten seconds is long enough for a cold start from a slow disk.
    if done.wait(timeout: .now() + 10) == .timedOut {
        return CocoaError(.executableLoad)
    }
    return failure
}

switch Invocation.parse(
    CommandLine.arguments,
    workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
{
case .help:
    print(Invocation.helpText)

case .version:
    print("pfadi \(pfadiVersion)")
    // And which bundle it would open, because the command and the application
    // are installed together and can still end up apart: a development build
    // registered with LaunchServices wins the lookup, and then `pfadi` opens
    // something other than what `pfadi --version` just said.
    if let bundle = findBundle(),
        let running = Bundle(url: bundle)?
            .infoDictionary?["CFBundleShortVersionString"] as? String
    {
        print("opens \(bundle.path) (\(running))")
    }

case .layoutCheck:
    // The application's own check, not this command's. Saying so beats
    // launching a window because an unknown flag looked like a path.
    fail("--layout-check belongs to the application, not to this command")

case .failed(let message):
    fail(message)

case .show(let targets):
    guard let bundle = findBundle() else {
        fail("cannot find Pfadi.app. Set PFADI_APP to it and try again.")
    }
    // A folder travels as a file URL, which is what LaunchServices and a drop
    // on the Dock icon both use. "Select this" cannot be said with a file URL,
    // so it travels as pfadi://reveal instead.
    let urls = targets.map { target -> URL in
        switch target {
        case .directory(let url): return url
        case .file(let url): return PfadiURL.reveal(url)
        }
    }
    if let error = open(urls, with: bundle) {
        fail("could not open \(bundle.lastPathComponent): \(error.localizedDescription)")
    }
}
