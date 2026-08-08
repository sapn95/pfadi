import Foundation
import PfadiCore

/// The command that fetches a share's password.
///
/// Most of these are about what must never happen. A feature that runs a
/// command somebody configured, on data that arrives off the network, to get a
/// secret, has three ways to go badly wrong: the data becomes code, the secret
/// is printed somewhere, or it hangs the window.
enum CredentialSuites {
    static func run() {
        parsing()
        substitution()
        safety()
        running()
    }

    private static func parsing() {
        Harness.suite("credentials: a command is split into arguments, not a shell line") {
            Harness.expectEqual(
                CredentialCommand("pass show filers/x")?.arguments,
                ["pass", "show", "filers/x"], "three arguments")
            Harness.expectEqual(
                CredentialCommand("  op   read   x  ")?.arguments,
                ["op", "read", "x"], "runs of spaces collapse")
        }

        Harness.suite("credentials: quotes hold a vault name together") {
            Harness.expectEqual(
                CredentialCommand("pass-cli item view --vault-name \"Work Filers\"")?.arguments,
                ["pass-cli", "item", "view", "--vault-name", "Work Filers"],
                "the two words stay one argument")
            Harness.expectEqual(
                CredentialCommand("x --title 'a b'")?.arguments, ["x", "--title", "a b"],
                "single quotes too")
        }

        Harness.suite("credentials: an empty argument survives being quoted") {
            Harness.expectEqual(
                CredentialCommand("cmd '' end")?.arguments, ["cmd", "", "end"],
                "an empty string is an argument somebody meant to pass")
        }

        Harness.suite("credentials: nonsense is refused rather than guessed at") {
            Harness.expect(
                CredentialCommand("pass 'unterminated") == nil,
                "an unclosed quote is a typo, and guessing where it ends is how a "
                    + "password goes into the wrong field")
            Harness.expect(CredentialCommand("") == nil, "and nothing is not a command")
            Harness.expect(CredentialCommand("   ") == nil, "nor is whitespace")
        }

        Harness.suite("credentials: it round-trips through the preference") {
            let store = MemoryStore()
            let preferences = Preferences(store: store)
            Harness.expect(preferences.credentialCommand == nil, "off unless somebody sets it")

            preferences.credentialCommand = CredentialCommand("pass-cli view \"My Vault\"")
            Harness.expectEqual(
                Preferences(store: store).credentialCommand?.arguments,
                ["pass-cli", "view", "My Vault"],
                "and the quoting survives a relaunch")
        }
    }

    private static func substitution() {
        Harness.suite("credentials: the placeholders are filled in") {
            let command = CredentialCommand("get {host} {share} {scheme}")!
            Harness.expectEqual(
                command.arguments(for: URL(string: "smb://filer97.sbb.ch/projects")!),
                ["get", "filer97.sbb.ch", "projects", "smb"],
                "host, share and scheme")
        }

        Harness.suite("credentials: a user comes from the caller or from the address") {
            let command = CredentialCommand("get {user}")!
            Harness.expectEqual(
                command.arguments(for: URL(string: "smb://sapn@filer/x")!), ["get", "sapn"],
                "from the address when it carries one")
            Harness.expectEqual(
                command.arguments(for: URL(string: "smb://filer/x")!, user: "asked"),
                ["get", "asked"], "and from the caller when it does not")
        }

        Harness.suite("credentials: a placeholder with nothing behind it becomes empty") {
            let command = CredentialCommand("get {user}")!
            Harness.expectEqual(
                command.arguments(for: URL(string: "smb://filer/x")!), ["get", ""],
                "an empty argument, not the word {user} handed to a program")
        }
    }

    private static func safety() {
        Harness.suite("credentials: a hostname cannot become a command") {
            // The whole reason this is argv and never a shell string. Through
            // a shell, this host would run rm. Through execve there is no
            // parser between here and the program that could disagree.
            let command = CredentialCommand("get {host}")!
            let hostile = URL(string: "smb://evil%3B%20rm%20-rf%20~/share")!
            let built = command.arguments(for: hostile)
            Harness.expectEqual(built.count, 2, "still exactly two arguments")
            Harness.expect(
                built[1].contains(";") || built[1].isEmpty,
                "whatever the host is, it arrives as one argument")
        }

        Harness.suite("credentials: a share name full of spaces stays one argument") {
            let command = CredentialCommand("get {share}")!
            let built = command.arguments(
                for: URL(string: "smb://filer/a%20b%20c%20--flag")!)
            Harness.expectEqual(built.count, 2, "two, however many spaces are in it")
            Harness.expectEqual(built[1], "a b c --flag", "and it is not split on them")
        }
    }

    private static func running() {
        Harness.suite("credentials: what the command prints is the password") {
            let command = CredentialCommand("/bin/echo hunter2")!
            Harness.expectEqual(
                CredentialRunner.run(command, for: URL(string: "smb://filer/x")!),
                .password("hunter2"), "with the newline taken off")
        }

        Harness.suite("credentials: nothing printed is a normal answer, not an error") {
            // A manager with no entry for this host has answered. The system's
            // own dialog is the next step, and calling that a failure would put
            // a red message in front of somebody for whom nothing went wrong.
            Harness.expectEqual(
                CredentialRunner.run(
                    CredentialCommand("/usr/bin/true")!, for: URL(string: "smb://filer/x")!),
                .nothing, "silence means it does not know this one")
        }

        Harness.suite("credentials: a non-zero exit is reported without the secret") {
            let command = CredentialCommand("/bin/sh -c 'echo topsecret; exit 3'")!
            // Note this is /bin/sh only because the *test* wants a program that
            // does two things. pfadi never puts a shell in the middle.
            guard
                case .failed(let why) = CredentialRunner.run(
                    command, for: URL(string: "smb://filer/x")!)
            else {
                Harness.expect(false, "exit 3 is a failure")
                return
            }
            Harness.expect(why.contains("3"), "the exit code is in the message, got \(why)")
            Harness.expect(
                !why.contains("topsecret"),
                "and what it printed on stdout is not, got \(why)")
        }

        Harness.suite("credentials: a secret echoed on stderr is redacted") {
            let command = CredentialCommand("/bin/sh -c 'echo s3cret; echo s3cret >&2; exit 1'")!
            guard
                case .failed(let why) = CredentialRunner.run(
                    command, for: URL(string: "smb://filer/x")!)
            else {
                Harness.expect(false, "exit 1 is a failure")
                return
            }
            Harness.expect(
                !why.contains("s3cret"),
                "a tool that repeats the password on its error output does not get "
                    + "it into the status line, got \(why)")
        }

        Harness.suite("credentials: a command that hangs is given up on") {
            let started = Date()
            guard
                case .failed(let why) = CredentialRunner.run(
                    CredentialCommand("/bin/sleep 30")!,
                    for: URL(string: "smb://filer/x")!,
                    timeout: 1)
            else {
                Harness.expect(false, "a command that never answers is a failure")
                return
            }
            Harness.expect(
                Date().timeIntervalSince(started) < 10,
                "and it does not wait for it, took \(Int(Date().timeIntervalSince(started)))s")
            Harness.expect(why.contains("second"), "saying so, got \(why)")
        }

        Harness.suite("credentials: a program that is not there is a message, not a crash") {
            guard
                case .failed(let why) = CredentialRunner.run(
                    CredentialCommand("/nope/not/a/program")!, for: URL(string: "smb://filer/x")!)
            else {
                Harness.expect(false, "a missing program is a failure")
                return
            }
            Harness.expect(!why.isEmpty, "with something a person can read, got \(why)")
        }
    }
}

extension CredentialSuites {
    /// The whole path, against a real password manager.
    ///
    /// Skipped unless PFADI_CREDENTIAL_CHECK names a command, because a check
    /// cannot assume anybody has one installed, let alone logged in. What it
    /// proves when it does run is the only thing the unit tests above cannot:
    /// that a real manager's output is what this code expects.
    static func runAgainstRealManager() {
        guard let template = ProcessInfo.processInfo.environment["PFADI_CREDENTIAL_CHECK"],
            let host = ProcessInfo.processInfo.environment["PFADI_CREDENTIAL_HOST"]
        else { return }

        Harness.suite("credentials: a real password manager answers") {
            guard let command = CredentialCommand(template) else {
                Harness.expect(false, "PFADI_CREDENTIAL_CHECK parses as a command")
                return
            }
            let share = URL(string: "smb://\(host)/share")!
            switch CredentialRunner.run(command, for: share) {
            case .password(let password):
                // The length, never the password. A check that printed it
                // would put it in a CI log.
                Harness.expect(
                    !password.isEmpty, "it answered with \(password.count) characters")
                Harness.expect(
                    !password.contains("\n"),
                    "on one line, which is what the mount is handed")
            case .nothing:
                Harness.expect(false, "it found nothing for \(host)")
            case .failed(let why):
                Harness.expect(false, "it failed: \(why)")
            }
        }
    }
}
