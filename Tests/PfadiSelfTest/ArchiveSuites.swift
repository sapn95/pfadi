import Foundation
import PfadiCore

/// Unpacking, against archives this suite makes with the system's own tools.
enum ArchiveSuites {
    static func run() {
        recognising()
        unpacking()
    }

    private static func recognising() {
        Harness.suite("archives: what is worth offering to unpack") {
            for name in [
                "report.zip", "REPORT.ZIP", "sources.tar", "sources.tar.gz", "sources.tgz",
                "sources.tar.bz2", "sources.txz", "library.jar",
            ] {
                Harness.expect(
                    Archives.canExpand(URL(fileURLWithPath: "/x/\(name)")),
                    "\(name) is one of them")
            }
            for name in ["notes.txt", "archive.rar", "bundle.7z", "photo.zipper", ".zip"] {
                Harness.expect(
                    !Archives.canExpand(URL(fileURLWithPath: "/x/\(name)")),
                    "\(name) is not")
            }
        }

        Harness.suite("archives: the name the result gets") {
            // The whole suffix, not pathExtension, which reads report.tar.gz as
            // a gz and would leave the result called report.tar.
            Harness.expectEqual(
                Archives.stem(of: URL(fileURLWithPath: "/x/report.tar.gz")), "report",
                "a two-part suffix comes off in one piece")
            Harness.expectEqual(
                Archives.stem(of: URL(fileURLWithPath: "/x/Report.ZIP")), "Report",
                "and the case on disk is kept")
        }
    }

    private static func unpacking() {
        Harness.suite("archives: a zip of several files becomes a folder") {
            try withSandbox([]) { root in
                let source = root.appendingPathComponent("stuff")
                try FileManager.default.createDirectory(
                    at: source, withIntermediateDirectories: true)
                for name in ["one.txt", "two.txt"] {
                    FileManager.default.createFile(
                        atPath: source.appendingPathComponent(name).path,
                        contents: Data("x".utf8))
                }
                guard let archive = zip(contentsOf: source, named: "bundle.zip", in: root) else {
                    Harness.expect(false, "the fixture zip was made")
                    return
                }
                try FileManager.default.removeItem(at: source)

                let landed = try Archives.expand(archive)
                Harness.expectEqual(
                    landed.lastPathComponent, "stuff",
                    "an archive holding one folder gives that folder, not a folder holding it")
                Harness.expectEqual(
                    (try? FileManager.default.contentsOfDirectory(atPath: landed.path))?
                        .sorted(),
                    ["one.txt", "two.txt"],
                    "with everything that was in it")
                Harness.expect(
                    FileManager.default.fileExists(atPath: archive.path),
                    "and the archive itself is left alone")
            }
        }

        Harness.suite("archives: unpacking twice does not overwrite the first") {
            try withSandbox([]) { root in
                let source = root.appendingPathComponent("stuff")
                try FileManager.default.createDirectory(
                    at: source, withIntermediateDirectories: true)
                FileManager.default.createFile(
                    atPath: source.appendingPathComponent("one.txt").path,
                    contents: Data("x".utf8))
                guard let archive = zip(contentsOf: source, named: "bundle.zip", in: root) else {
                    Harness.expect(false, "the fixture zip was made")
                    return
                }

                let second = try Archives.expand(archive)
                Harness.expectEqual(
                    second.lastPathComponent, "stuff 2",
                    "the second one gets its own name rather than replacing anything")
                Harness.expect(
                    FileManager.default.fileExists(
                        atPath: source.appendingPathComponent("one.txt").path),
                    "and what was already there is untouched")
            }
        }

        Harness.suite("archives: nothing is left behind when it fails") {
            try withSandbox(["broken.zip"]) { root in
                // A text file with a zip name: ditto refuses it, and the
                // staging folder must not survive the refusal.
                let archive = root.appendingPathComponent("broken.zip")
                do {
                    _ = try Archives.expand(archive)
                    Harness.expect(false, "a file that is not a zip cannot unpack")
                } catch let problem as Archives.Problem {
                    Harness.expect(
                        !problem.message.isEmpty, "it says why, got \(problem.message)")
                }
                let left =
                    (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
                Harness.expectEqual(
                    left.sorted(), ["broken.zip"], "and the staging folder is gone")
            }
        }

        Harness.suite("archives: something nothing here unpacks says so") {
            let problem = Archives.Problem.unsupported("rar")
            Harness.expectEqual(
                problem.message, "nothing here unpacks a .rar", "by name, so it can be acted on")
        }
    }

    /// A real archive, made by the tool that made every zip on this machine.
    private static func zip(contentsOf folder: URL, named: String, in root: URL) -> URL? {
        let archive = root.appendingPathComponent(named)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", folder.path, archive.path]
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? archive : nil
    }
}
