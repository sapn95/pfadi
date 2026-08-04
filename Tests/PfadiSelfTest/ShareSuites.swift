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
