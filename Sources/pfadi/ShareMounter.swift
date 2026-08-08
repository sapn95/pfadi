import AppKit
import NetFS
import PfadiCore

/// Mounts a share and reports where it landed.
enum ShareMounter {
    enum Result {
        case alreadyMounted(URL)
        case mounted(URL)
        case needsCredentials
        /// The configured credential command ran and could not help. Its own
        /// words, never the password: what a password manager prints on stdout
        /// is the secret and never reaches here.
        case credentialCommandFailed(String)
        case failed(String)
    }

    /// Mounts `url`, or finds it already mounted.
    ///
    /// `NetFSMountURLSync` blocks until the server answers, and an unreachable
    /// server takes as long as the timeout: never on the main thread, or the
    /// application freezes for a typo.
    /// - Parameter credentials: a command to ask for a password when the
    ///   system says it needs one. Asked second, never first: the keychain
    ///   already answers for anything Finder has connected to, and running
    ///   somebody's password manager for a share that needed no password would
    ///   be a prompt nobody asked for.
    static func mount(
        _ url: URL,
        credentials: CredentialCommand? = nil,
        then report: @escaping (Result) -> Void
    ) {
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
                    guard let credentials else {
                        report(.needsCredentials)
                        return
                    }
                    askAndRetry(url, credentials: credentials, then: report)
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

    /// Runs the configured command and tries the mount again with what it
    /// said.
    ///
    /// On its own queue, because a password manager may put a Touch ID prompt
    /// on screen and that is not something to do on the main thread.
    private static func askAndRetry(
        _ url: URL,
        credentials: CredentialCommand,
        then report: @escaping (Result) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = CredentialRunner.run(credentials, for: url)
            switch outcome {
            case .nothing:
                // No entry for this host is a normal answer. The system's own
                // dialog is the right next step, not an error.
                DispatchQueue.main.async { report(.needsCredentials) }
            case .failed(let why):
                DispatchQueue.main.async { report(.credentialCommandFailed(why)) }
            case .password(let password):
                var mountpoints: Unmanaged<CFArray>?
                let user = url.user
                let status = NetFSMountURLSync(
                    url as CFURL, nil, user as CFString?, password as CFString,
                    nil, nil, &mountpoints)
                let mounted = (mountpoints?.takeRetainedValue() as? [String])?.first

                DispatchQueue.main.async {
                    if status == 0, let mounted {
                        report(.mounted(URL(fileURLWithPath: mounted, isDirectory: true)))
                    } else if status == 0 {
                        let found = NetworkShare.existingMount(
                            for: url, in: NetworkShare.currentMounts())
                        report(found.map(Result.mounted) ?? .needsCredentials)
                    } else if isAuthentication(status) {
                        // It answered and the answer was wrong. Saying so
                        // beats a second dialog that looks like the first one
                        // failed for no reason.
                        report(.credentialCommandFailed("the password it gave was not accepted"))
                    } else {
                        report(.failed(message(for: status)))
                    }
                }
            }
        }
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
