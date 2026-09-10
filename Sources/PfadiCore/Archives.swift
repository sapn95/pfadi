import Foundation

/// Unpacking an archive, and landing on what came out of it.
///
/// Handing a `.zip` to the system opens Archive Utility, which expands it
/// somewhere and tells nobody. From a file browser that reads as nothing
/// happening: the window still shows the folder as it was, until the watcher
/// notices a folder has appeared and quietly adds a row somewhere down the
/// list. Doing the work here instead is the only way to know when it is done
/// and where the result went, which is the thing worth going to.
public enum Archives {
    /// What went wrong, in words somebody can act on.
    public enum Problem: Error, Equatable {
        /// Nothing on this machine expands that kind of file.
        case unsupported(String)
        /// The tool ran and said no.
        case failed(String)

        public var message: String {
            switch self {
            case .unsupported(let ext):
                return ext.isEmpty
                    ? "that is not an archive"
                    : "nothing here unpacks a .\(ext)"
            case .failed(let reason):
                return reason
            }
        }
    }

    /// The suffixes that are worth trying, longest first.
    ///
    /// Matched against the whole name rather than through `pathExtension`,
    /// which reads `report.tar.gz` as a `gz` and would send a tarball to the
    /// wrong tool.
    private static let known: [(suffix: String, program: String)] = [
        (".tar.gz", "/usr/bin/tar"),
        (".tar.bz2", "/usr/bin/tar"),
        (".tar.xz", "/usr/bin/tar"),
        (".tar.zst", "/usr/bin/tar"),
        (".tar", "/usr/bin/tar"),
        (".tgz", "/usr/bin/tar"),
        (".tbz", "/usr/bin/tar"),
        (".tbz2", "/usr/bin/tar"),
        (".txz", "/usr/bin/tar"),
        // ditto rather than tar for zip: it is what Archive Utility uses, and
        // it keeps the resource forks and extended attributes a Mac zip
        // carries. bsdtar reads zip too and drops them.
        (".zip", "/usr/bin/ditto"),
        (".jar", "/usr/bin/ditto"),
    ]

    /// Whether this is something the tools on every Mac can unpack.
    ///
    /// `.rar` and `.7z` are deliberately absent: expanding one needs software
    /// that may not be installed, and an Unzip that sometimes does nothing is
    /// worse than one that is not offered.
    public static func canExpand(_ url: URL) -> Bool { program(for: url) != nil }

    private static func program(for url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        // The suffix, not the whole name: a file called ".zip" and nothing else
        // is a dotfile, not an archive.
        return known.first { name.count > $0.suffix.count && name.hasSuffix($0.suffix) }?.program
    }

    /// The name to give what comes out, with the suffix taken off.
    public static func stem(of url: URL) -> String {
        let name = url.lastPathComponent
        let lowered = name.lowercased()
        guard let match = known.first(where: { lowered.hasSuffix($0.suffix) }) else { return name }
        return String(name.dropLast(match.suffix.count))
    }

    /// Unpacks `url` beside itself and says where the result landed.
    ///
    /// Blocking, and meant to be called off the main queue: a large archive
    /// takes as long as it takes, and a window that stops answering while it
    /// runs is worse than one that says what it is doing.
    ///
    /// The result is a single URL because that is what somebody wants to be
    /// taken to. An archive holding one folder gives that folder, rather than a
    /// folder holding a folder of the same name, which is the thing everybody
    /// complains about when they unzip by hand.
    @discardableResult
    public static func expand(
        _ url: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let program = program(for: url) else {
            throw Problem.unsupported(url.pathExtension.lowercased())
        }

        let parent = url.deletingLastPathComponent()
        // Staged inside the destination folder rather than in a temporary one,
        // so finishing is a rename on the same volume rather than a second copy
        // of everything that was just written.
        let staging = parent.appendingPathComponent(".pfadi-unpacking-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let arguments: [String]
        if program.hasSuffix("ditto") {
            arguments = ["-x", "-k", "--", url.path, staging.path]
        } else {
            arguments = ["-x", "-f", url.path, "-C", staging.path]
        }
        if let complaint = try run(program, arguments) {
            throw Problem.failed(complaint)
        }

        let unpacked = try contents(of: staging, fileManager: fileManager)
        guard !unpacked.isEmpty else { throw Problem.failed("the archive was empty") }

        // One thing inside, so that thing is the answer. Several, so the folder
        // holding them is.
        let source = unpacked.count == 1 ? unpacked[0] : staging
        let wanted = unpacked.count == 1 ? unpacked[0].lastPathComponent : stem(of: url)
        let destination = parent.appendingPathComponent(
            FileOperations.availableName(wanted, in: parent, fileManager: fileManager))
        try fileManager.moveItem(at: source, to: destination)
        return destination
    }

    /// What is actually in the staging folder, ignoring the bookkeeping.
    ///
    /// A zip made on a Mac carries a `__MACOSX` folder beside the real content,
    /// and counting it means an archive with one folder in it looks like an
    /// archive with two.
    private static func contents(
        of staging: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: nil, options: []
        )
        .filter { !["__MACOSX", ".DS_Store"].contains($0.lastPathComponent) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Runs a tool and hands back what it complained about, or nothing.
    ///
    /// argv, never a shell: an archive called `; rm -rf ~.zip` is a file name,
    /// and with `execve` there is no parser between here and the program that
    /// could read it as anything else.
    private static func run(_ program: String, _ arguments: [String]) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw Problem.failed("could not run \(program): \(error.localizedDescription)")
        }
        // Read before waiting: a tool that fills the pipe blocks until somebody
        // empties it, and waiting first would deadlock on a noisy failure.
        let complaint = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus != 0 else { return nil }
        let said = String(decoding: complaint, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map(String.init)
        return said?.isEmpty == false
            ? said : "\(URL(fileURLWithPath: program).lastPathComponent) refused it"
    }
}
