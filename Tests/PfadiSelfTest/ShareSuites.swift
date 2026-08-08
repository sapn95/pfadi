import Foundation
import PfadiCore

enum ShareSuites {
    static func run() {
        recognising()
        matching()
        assembling()
        listing()
    }

    private static func recognising() {
        Harness.suite("shares: what counts as one") {
            Harness.expectEqual(
                NetworkShare.url(from: "smb://server/share")?.host, "server", "smb")
            Harness.expectEqual(
                NetworkShare.url(from: "nfs://filer.example.com/export")?.host,
                "filer.example.com", "nfs")
            Harness.expectEqual(
                NetworkShare.url(from: "SMB://Server/Share")?.host, "Server",
                "the scheme is matched without case")
            Harness.expect(NetworkShare.url(from: "afp://old/share") != nil, "afp")
            Harness.expect(NetworkShare.url(from: "cifs://server/share") != nil, "cifs")
        }

        Harness.suite("shares: what does not") {
            Harness.expect(NetworkShare.url(from: "/Users/someone/git") == nil, "a path")
            Harness.expect(NetworkShare.url(from: "~/git") == nil, "a path with a tilde")
            Harness.expect(NetworkShare.url(from: "") == nil, "nothing")
            // A scheme with no host is not somewhere you can go, and treating
            // it as a share would swallow the error instead of reporting it.
            Harness.expect(NetworkShare.url(from: "smb://") == nil, "a scheme with no server")
            Harness.expect(
                NetworkShare.url(from: "mailto:someone@example.com") == nil,
                "a scheme that is not a filesystem")
        }
    }

    private static func matching() {
        let mounts = [
            NetworkShare.Mount(
                from: "//sapn@fileserver/projects",
                on: URL(fileURLWithPath: "/Volumes/projects", isDirectory: true)),
            NetworkShare.Mount(
                from: "//fileserver/archive",
                on: URL(fileURLWithPath: "/Volumes/archive", isDirectory: true)),
            NetworkShare.Mount(
                from: "filer.example.com:/export/data",
                on: URL(fileURLWithPath: "/Volumes/data", isDirectory: true)),
            NetworkShare.Mount(
                from: "/dev/disk1s1", on: URL(fileURLWithPath: "/", isDirectory: true)),
        ]

        Harness.suite("shares: finding one that is already mounted") {
            // Mounting something twice produces a second mount point with a
            // number on the end, which is how people end up with share-1
            // through share-4 and no idea which is which.
            Harness.expectEqual(
                NetworkShare.existingMount(
                    for: URL(string: "smb://fileserver/projects")!, in: mounts)?.path,
                "/Volumes/projects",
                "found, and the user in the mount is not matched on")

            Harness.expectEqual(
                NetworkShare.existingMount(
                    for: URL(string: "smb://FILESERVER/Archive")!, in: mounts)?.path,
                "/Volumes/archive",
                "and case does not matter on either side")
        }

        Harness.suite("shares: not confusing one share for another") {
            Harness.expect(
                NetworkShare.existingMount(
                    for: URL(string: "smb://fileserver/somethingelse")!, in: mounts) == nil,
                "same server, different share, so not mounted")
            Harness.expect(
                NetworkShare.existingMount(
                    for: URL(string: "smb://otherserver/projects")!, in: mounts) == nil,
                "same share name on a different server is a different share")
            Harness.expect(
                NetworkShare.existingMount(for: URL(string: "smb://dev/disk1s1")!, in: mounts)
                    == nil,
                "and a local disk is not a share")
            Harness.expect(
                NetworkShare.networkSource("/dev/disk1s1") == nil,
                "a device path is not a network source at all")
        }

        Harness.suite("shares: nfs uses a different spelling entirely") {
            // //server/share for SMB, server:/export for NFS. Comparing them
            // needs both reduced to the same shape first.
            Harness.expectEqual(
                NetworkShare.existingMount(
                    for: URL(string: "nfs://filer.example.com/export/data")!, in: mounts)?.path,
                "/Volumes/data",
                "an export path matches the colon form")
            Harness.expect(
                NetworkShare.existingMount(
                    for: URL(string: "nfs://filer.example.com/export/other")!, in: mounts) == nil,
                "a different export on the same filer is not it")
        }

        Harness.suite("shares: a server with no share names the whole server") {
            Harness.expectEqual(
                NetworkShare.existingMount(for: URL(string: "smb://fileserver")!, in: mounts)?.path,
                "/Volumes/projects",
                "any mount from that server will do")
        }
    }

    private static func assembling() {
        Harness.suite("connect: what people paste, understood") {
            // A colleague sends what their machine showed them, and what a
            // Windows machine shows is backslashes.
            let unc = NetworkShare.interpret("\\\\filer\\projects", scheme: "smb")
            Harness.expectEqual(
                unc?.url, URL(string: "smb://filer/projects"), "a UNC path is an smb share")
            Harness.expect(unc?.wasRewritten == true, "and it says it changed it")
            Harness.expectEqual(
                unc?.rewrittenFrom, "\\\\filer\\projects", "quoting the original back")

            Harness.expectEqual(
                NetworkShare.interpret("\\\\filer\\team share\\docs", scheme: "smb")?.url,
                URL(string: "smb://filer/team%20share/docs"),
                "a space is legal in a share name and not in a URL")

            Harness.expectEqual(
                NetworkShare.interpret("filer:/export/data", scheme: "smb")?.url,
                URL(string: "nfs://filer/export/data"),
                "the colon form is nfs, whichever button is lit")

            Harness.expectEqual(
                NetworkShare.interpret("//filer/projects/", scheme: "smb")?.url,
                URL(string: "smb://filer/projects"),
                "slashes either end are noise")

            let plain = NetworkShare.interpret("smb://filer/projects", scheme: "nfs")
            Harness.expect(
                plain?.wasRewritten == false, "a real address is not a rewrite, so nothing is said")
        }

        Harness.suite("connect: the magic can be turned off") {
            Harness.expect(
                NetworkShare.interpret("\\\\filer\\projects", scheme: "smb", rewriting: false)
                    == nil,
                "with rewriting off a UNC path is refused rather than reinterpreted")
            Harness.expectEqual(
                NetworkShare.interpret("smb://filer/projects", scheme: "smb", rewriting: false)?
                    .url,
                URL(string: "smb://filer/projects"),
                "but a real address still works")
        }

        Harness.suite("connect: what gets typed becomes a URL") {
            Harness.expectEqual(
                NetworkShare.assemble(scheme: "smb", from: "fileserver/projects"),
                URL(string: "smb://fileserver/projects"),
                "server and share")
            Harness.expectEqual(
                NetworkShare.assemble(scheme: "nfs", from: "filer/export/data"),
                URL(string: "nfs://filer/export/data"),
                "an nfs export path")

            // The two things everybody does: leading slashes, and pasting a
            // whole URL in while a different button is lit.
            Harness.expectEqual(
                NetworkShare.assemble(scheme: "smb", from: "//fileserver/projects"),
                URL(string: "smb://fileserver/projects"),
                "leading slashes are forgiven")
            Harness.expectEqual(
                NetworkShare.assemble(scheme: "smb", from: "nfs://filer/export"),
                URL(string: "nfs://filer/export"),
                "a pasted URL wins over the button")

            Harness.expect(
                NetworkShare.assemble(scheme: "smb", from: "") == nil, "nothing typed")
            Harness.expect(
                NetworkShare.assemble(scheme: "smb", from: "   ") == nil, "only spaces")
            Harness.expect(
                NetworkShare.assemble(scheme: "smb", from: "///") == nil,
                "slashes and nothing else")
        }
    }

    private static func listing() {
        Harness.suite("shares: the kernel really does answer") {
            let mounts = NetworkShare.currentMounts()
            Harness.expect(!mounts.isEmpty, "there is at least one filesystem mounted")
            Harness.expect(
                mounts.contains { $0.on.path == "/" }, "and one of them is the root")
            Harness.expect(
                mounts.allSatisfy { !$0.from.isEmpty }, "every one says what it came from")
        }
    }
}

extension ShareSuites {
    /// What a share is called in a sidebar 170 points wide.
    static func runTitles() {
        Harness.suite("sidebar: a share is named by its share, not its host") {
            // The host does not fit. What arrived on screen was
            // "testfiler-pr…ma.sbb.ch", which has lost both the part saying
            // which filer and the part saying which share.
            Harness.expectEqual(
                NetworkShare.title(
                    for: URL(string: "smb://testfiler-prod-01.filer.sigma.sbb.ch/projects")!),
                "projects", "the share name")
            Harness.expectEqual(
                NetworkShare.title(for: URL(string: "nfs://filer/export/data")!),
                "export", "the first component, not the whole path")
        }

        Harness.suite("sidebar: a host with no share falls back to the host") {
            Harness.expectEqual(
                NetworkShare.title(for: URL(string: "smb://filer.example.com")!),
                "filer.example.com", "there is nothing else to call it")
        }

        Harness.suite("sidebar: an escaped share name is readable") {
            Harness.expectEqual(
                NetworkShare.title(
                    for: URL(string: "smb://filer/team%20share")!),
                "team share", "rather than showing the percent signs")
        }
    }
}

extension ShareSuites {
    /// A share name that contains a percent sign.
    static func runEscaping() {
        Harness.suite("sidebar: a share is decoded once, not twice") {
            // pathComponents already decodes. Decoding again turns a share
            // genuinely named "100%25" into "100%", which is a different name.
            Harness.expectEqual(
                NetworkShare.title(for: URL(string: "smb://filer/100%2525")!), "100%25",
                "the name on the filer, not one percent-decode further")
        }
    }
}

extension ShareSuites {
    /// What the path bar may and may not read as a server.
    static func runPathBarReading() {
        Harness.suite("path bar: a UNC path is a server") {
            Harness.expectEqual(
                NetworkShare.unambiguousShare(from: "\\\\filer\\share", rewriting: true)?
                    .url.absoluteString,
                "smb://filer/share",
                "which is the whole reason this exists: it worked in the sheet and "
                    + "did nothing in the bar")
            Harness.expectEqual(
                NetworkShare.unambiguousShare(from: "\\\\filer\\team share\\docs", rewriting: true)?
                    .url.absoluteString,
                "smb://filer/team%20share/docs", "spaces and all")
        }

        Harness.suite("path bar: a relative path is NOT a server") {
            // The regression this nearly shipped with. The connect sheet reads
            // `filer/share` as a share because you are already naming a server
            // there; in the path bar the same text is a folder, and reading it
            // as smb:// would take somebody typing Sources/PfadiCore to a
            // machine called Sources.
            for local in ["Sources/PfadiCore", "docs/credentials.md", "a/b/c", "Downloads"] {
                Harness.expect(
                    NetworkShare.unambiguousShare(from: local, rewriting: true) == nil,
                    "\(local) is a path, not a server")
            }
        }

        Harness.suite("path bar: an address that names its scheme is taken as one") {
            Harness.expectEqual(
                NetworkShare.unambiguousShare(from: "smb://filer/share", rewriting: false)?
                    .url.absoluteString,
                "smb://filer/share", "even with rewriting off, because nothing was rewritten")
            Harness.expect(
                NetworkShare.unambiguousShare(from: "\\\\filer\\share", rewriting: false) == nil,
                "and with rewriting off a UNC path is left alone")
        }
    }
}

extension ShareSuites {
    /// The list of servers you have connected to before.
    static func runKnownServers() {
        Harness.suite("servers: one can be forgotten") {
            // There was no way to. A server typed once with a spelling mistake
            // stayed in the list for good.
            let store = MemoryStore()
            let favourites = Favourites(preferences: Preferences(store: store))
            favourites.rememberServer(URL(string: "smb://filer97.sbb.ch/projects")!)
            favourites.rememberServer(URL(string: "smb://typo-filer/share")!)
            Harness.expectEqual(favourites.servers().count, 2, "both remembered")

            Harness.expect(
                favourites.forgetServer(URL(string: "smb://typo-filer/share")!),
                "and the mistake can go")
            Harness.expectEqual(
                favourites.servers().map(\.absoluteString), ["smb://filer97.sbb.ch/projects"],
                "leaving the other alone")
            Harness.expect(
                !favourites.forgetServer(URL(string: "smb://never-seen/x")!),
                "forgetting one that was never there changes nothing and says so")
        }

        Harness.suite("servers: the user is part of the address") {
            // It was dropped when a recent was picked, so connecting to a share
            // you reach as somebody else put you back to guessing.
            let store = MemoryStore()
            let favourites = Favourites(preferences: Preferences(store: store))
            let withUser = URL(string: "smb://sapn@filer97.sbb.ch/projects")!
            favourites.rememberServer(withUser)
            Harness.expectEqual(
                favourites.servers().first?.user, "sapn", "remembered with it")
        }
    }
}
