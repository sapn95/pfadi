import AppKit
import NetFS
import PfadiCore

/// Mounts a share and reports where it landed.
enum ShareMounter {
    enum Result {
        case alreadyMounted(URL)
        case mounted(URL)
        case needsCredentials
        case failed(String)
    }

    /// Mounts `url`, or finds it already mounted.
    ///
    /// `NetFSMountURLSync` blocks until the server answers, and an unreachable
    /// server takes as long as the timeout: never on the main thread, or the
    /// application freezes for a typo.
    static func mount(_ url: URL, then report: @escaping (Result) -> Void) {
        if let existing = NetworkShare.existingMount(for: url, in: NetworkShare.currentMounts()) {
            report(.alreadyMounted(existing))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var mountpoints: Unmanaged<CFArray>?
            // No credentials passed: this uses the keychain and, failing that,
            // guest. Anything needing a prompt is handed to the system, which
            // already has a connect dialog nobody needs a second version of.
            let status = NetFSMountURLSync(
                url as CFURL, nil, nil, nil, nil, nil, &mountpoints)

            let mounted = (mountpoints?.takeRetainedValue() as? [String])?.first
            DispatchQueue.main.async {
                if status == 0, let mounted {
                    report(.mounted(URL(fileURLWithPath: mounted, isDirectory: true)))
                } else if status == 0 {
                    // Mounted, but it declined to say where. Ask the kernel.
                    let found = NetworkShare.existingMount(
                        for: url, in: NetworkShare.currentMounts())
                    report(found.map(Result.mounted) ?? .failed("mounted, but not where it said"))
                } else if isAuthentication(status) {
                    report(.needsCredentials)
                } else {
                    report(.failed(message(for: status)))
                }
            }
        }
    }

    /// Hands the URL to the system, which puts up the same connect and
    /// authenticate sheet Finder uses.
    static func askSystemToConnect(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private static func isAuthentication(_ status: Int32) -> Bool {
        // EAUTH, EACCES and EPERM all mean "who are you", from different
        // layers. ENETFSPWDNEEDSCHANGE and friends live above 6000.
        status == 80 || status == 13 || status == 1 || status >= 6000
    }

    /// Errors people can act on, rather than a number to search for.
    private static func message(for status: Int32) -> String {
        switch status {
        case 2:
            return "no such share on that server. Check the part after the last slash"
        case 22:
            return "that address is not one this protocol understands"
        case 51, 65:
            return "cannot reach that server. Check the name, and whether the VPN is up"
        case 60:
            return "the server did not answer in time"
        case 64:
            return "the server is not answering on this protocol. SMB and NFS are not the same"
        default:
            return "the server refused (error \(status))"
        }
    }
}
