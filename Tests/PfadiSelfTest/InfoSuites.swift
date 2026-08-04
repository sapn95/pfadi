import Foundation
import PfadiCore

enum InfoSuites {
    static func run() {
        permissions()
        cloud()
        gathering()
    }

    private static func permissions() {
        Harness.suite("permissions: the spelling everyone reads without thinking") {
            Harness.expectEqual(FileInfo.permissionString(0o755), "rwxr-xr-x", "an executable")
            Harness.expectEqual(FileInfo.permissionString(0o644), "rw-r--r--", "an ordinary file")
            Harness.expectEqual(FileInfo.permissionString(0o600), "rw-------", "a private one")
            Harness.expectEqual(FileInfo.permissionString(0o000), "---------", "nothing at all")
            Harness.expectEqual(FileInfo.permissionString(0o777), "rwxrwxrwx", "everything")
        }
    }

    private static func cloud() {
        Harness.suite("cloud: an ordinary file is not in anyone's cloud") {
            let status = CloudFiles.status(of: URL(fileURLWithPath: "/Users/someone/git/README.md"))
            Harness.expect(!status.isCloud, "no provider")
            Harness.expect(status.summary == nil, "and nothing to say about it")
        }

        Harness.suite("cloud: the provider comes out of the path") {
            let onedrive = URL(
                fileURLWithPath: "/Users/someone/Library/CloudStorage/OneDrive-SBB/report.xlsx")
            let found = CloudFiles.provider(for: onedrive)
            Harness.expectEqual(found?.provider, "OneDrive", "the provider")
            Harness.expectEqual(found?.account, "SBB", "and which account")

            let dropbox = URL(
                fileURLWithPath: "/Users/someone/Library/CloudStorage/Dropbox/notes.txt")
            Harness.expectEqual(
                CloudFiles.provider(for: dropbox)?.provider, "Dropbox", "one without an account")
            Harness.expect(
                CloudFiles.provider(for: dropbox)?.account == nil, "has no account to report")

            let icloud = URL(
                fileURLWithPath:
                    "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/thing.pages")
            Harness.expectEqual(
                CloudFiles.provider(for: icloud)?.provider, "iCloud Drive", "and iCloud")
        }

        Harness.suite("cloud: a folder called CloudStorage somewhere else is not a provider") {
            // The check is anchored on Library/CloudStorage, so somebody's own
            // folder of that name is left alone.
            let decoy = URL(fileURLWithPath: "/Users/someone/git/CloudStorage/OneDrive-SBB/x.txt")
            Harness.expect(CloudFiles.provider(for: decoy) == nil, "not treated as OneDrive")
        }

        Harness.suite("cloud: what it says out loud") {
            let online = CloudFiles.Status(
                provider: "OneDrive", account: "SBB", isDownloaded: false)
            Harness.expectEqual(online.summary, "OneDrive (SBB), online only", "a placeholder")

            let here = CloudFiles.Status(provider: "Dropbox", account: nil, isDownloaded: true)
            Harness.expectEqual(here.summary, "Dropbox, downloaded", "and one that is really here")
        }

        Harness.suite("cloud: an ordinary local file is not dataless") {
            try withSandbox(["real.txt"]) { root in
                Harness.expect(
                    !CloudFiles.isDataless(root.appendingPathComponent("real.txt")),
                    "a file with bytes in it")
                Harness.expect(
                    !CloudFiles.isDataless(root.appendingPathComponent("missing.txt")),
                    "and a file that is not there at all does not claim to be a placeholder")
            }
        }
    }

    private static func gathering() {
        Harness.suite("info: what it finds on a real file") {
            try withSandbox(["thing.txt"]) { root in
                let url = root.appendingPathComponent("thing.txt")
                let info = FileInfo.gather(url)

                Harness.expectEqual(info.name, "thing.txt", "the name")
                Harness.expectEqual(info.size, 1, "the size, one byte of x")
                Harness.expect(!info.isDirectory, "not a folder")
                Harness.expect(info.modified != nil, "a modification date")
                Harness.expect(info.permissions != nil, "and permissions")
                Harness.expectEqual(
                    info.owner, NSUserName(), "owned by whoever is running the tests")
                Harness.expect(!info.cloud.isCloud, "and not in a cloud")
            }
        }

        Harness.suite("info: a folder reports itself as one") {
            try withSandbox(["stuff"], directories: ["stuff"]) { root in
                let info = FileInfo.gather(root.appendingPathComponent("stuff"))
                Harness.expect(info.isDirectory, "it knows")
            }
        }
    }
}
