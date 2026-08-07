import Foundation

/// What a command line asked for.
///
/// Shared by the `pfadi` command and by the application itself, so that
/// `pfadi ~/git` and a bundle launched with the same argument cannot disagree
/// about what was meant. It is pure: it reads the filesystem to decide whether
/// a path is a folder and nothing else, which is why it can be tested.
public enum Invocation: Equatable {
    /// Show these. A folder is opened; a file has its folder opened with the
    /// file selected, which is the only useful reading of "show me this file".
    case show([PathCompletion.Target])
    case help
    case version
    /// The application's own off-screen layout check. Not documented in `help`:
    /// it is for CI, not for people.
    case layoutCheck
    /// Something was wrong with the arguments. The string is the whole message.
    case failed(String)

    /// Reads `arguments` as given to `main`, including the program name.
    ///
    /// - Parameters:
    ///   - arguments: `CommandLine.arguments`, program name and all.
    ///   - workingDirectory: what a bare `pfadi` means, and what a relative
    ///     path is relative to.
    public static func parse(
        _ arguments: [String],
        workingDirectory: URL,
        fileManager: FileManager = .default
    ) -> Invocation {
        // One list, in the order they were typed. Keeping the reveals in a
        // second list sorted them ahead of everything else, so
        // `pfadi ~/git -R notes.txt` and `pfadi -R notes.txt ~/git` opened
        // their tabs in the same order whichever way round they were written.
        var asked: [(path: String, reveal: Bool)] = []

        // Everything after `--` is a path, however much it looks like a flag.
        // A folder really can be called `--help`, and refusing to open it
        // because of that is the kind of detail that makes a tool feel cheap.
        var literal = false
        var iterator = arguments.dropFirst().makeIterator()

        while let argument = iterator.next() {
            if literal {
                asked.append((path: argument, reveal: false))
                continue
            }
            switch argument {
            case "--":
                literal = true
            case "-h", "--help":
                return .help
            case "-v", "--version":
                return .version
            case "--layout-check":
                return .layoutCheck
            case "-R", "--reveal":
                guard let next = iterator.next() else {
                    return .failed("\(argument) needs a path after it")
                }
                asked.append((path: next, reveal: true))
            default:
                // A lone "-" is a path in the sense that it is not an option,
                // and it will fail the existence check below like any other
                // path that is not there. Anything else starting with a dash
                // is a typo, and guessing at a typo opens the wrong folder.
                if argument.hasPrefix("-"), argument != "-" {
                    return .failed("unknown option: \(argument)")
                }
                asked.append((path: argument, reveal: false))
            }
        }

        // Nothing to go on: the folder the shell is standing in.
        guard !asked.isEmpty else {
            return .show([.directory(PathCompletion.directoryURL(workingDirectory))])
        }

        var targets: [PathCompletion.Target] = []
        for item in asked {
            var isDirectory: ObjCBool = false
            let url = absolute(item.path, relativeTo: workingDirectory)
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return .failed("no such file or folder: \(item.path)")
            }
            // -R means "select this", even for a folder. Without the override
            // a folder would be opened rather than pointed at, which is the
            // opposite of what was asked for.
            targets.append(
                isDirectory.boolValue && !item.reveal
                    ? .directory(PathCompletion.directoryURL(url))
                    : .file(url.standardizedFileURL))
        }
        return .show(targets)
    }

    private static func absolute(_ path: String, relativeTo base: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : base.appendingPathComponent(expanded)
    }

    /// The text `--help` prints.
    ///
    /// Kept here rather than at the call site because the man page is checked
    /// against it: every option named in one has to appear in the other, and a
    /// check can only do that if there is a single string to read.
    public static let helpText = """
        pfadi — a file browser with an address bar you can click into and type.

        usage: pfadi [folder ...]
               pfadi -R <path>
               pfadi --help | --version

          (no arguments)    the folder the shell is in
          <folder>          open it; several open as tabs of one window
          <file>            open the folder holding it, with the file selected
          -R, --reveal      select this, even when it is a folder
          --                everything after this is a path, not an option

        pfadi returns as soon as the window is asked for, so it can be put at
        the end of a line without holding the terminal.

        To use it in place of Finder as far as macOS allows: pfadi-default apply
        """
}
