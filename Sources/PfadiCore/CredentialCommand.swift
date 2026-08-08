import Foundation

/// A command that hands back the password for a share.
///
/// Deliberately not "Proton Pass support". pfadi knows nothing about any
/// password manager and never will: it runs a command somebody has configured
/// and reads one line from it. That works with Proton Pass through `pass-cli`,
/// with 1Password through `op`, with `pass`, with `bw`, and with a shell script
/// somebody wrote themselves. Naming one of them in the code would be a
/// dependency on a company.
///
/// The same shape `git config credential.helper` has, for the same reason.
public struct CredentialCommand: Equatable, Sendable {
    /// The program and its arguments, already split.
    ///
    /// An array rather than a string, and this is the security decision in the
    /// whole feature: nothing here is handed to a shell. A share on a host
    /// called `filer; rm -rf ~` is a hostname, not a command, and with argv
    /// there is no parser between here and `execve` that could disagree.
    public let arguments: [String]

    public init(arguments: [String]) {
        self.arguments = arguments
    }

    /// What a person types into the preference.
    ///
    /// Split on whitespace, honouring single and double quotes so a vault
    /// called "Work Filers" survives. Not a shell: no globbing, no variables,
    /// no pipes, no `$(…)`. Anything more than quoting belongs in a script the
    /// person writes and points this at.
    public init?(_ text: String) {
        var arguments: [String] = []
        var current = ""
        var quote: Character?
        var sawAny = false

        for character in text {
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                sawAny = true
            case " ", "\t":
                if sawAny || !current.isEmpty {
                    arguments.append(current)
                    current = ""
                    sawAny = false
                }
            default:
                current.append(character)
            }
        }
        // An unterminated quote is a typo, not an argument. Guessing where it
        // was meant to close is how a password ends up in the wrong field.
        guard quote == nil else { return nil }
        if sawAny || !current.isEmpty { arguments.append(current) }

        guard !arguments.isEmpty else { return nil }
        self.arguments = arguments
    }

    /// The command with the placeholders filled in for one share.
    ///
    /// Substituted per argument rather than across the whole string, so a value
    /// can never split one argument into two however many spaces it contains.
    public func arguments(for share: URL, user: String? = nil) -> [String] {
        let replacements: [String: String] = [
            "{host}": share.host ?? "",
            "{share}": NetworkShare.title(for: share),
            "{user}": user ?? share.user ?? "",
            "{scheme}": share.scheme ?? "",
            "{url}": share.absoluteString,
        ]
        return arguments.map { argument in
            var filled = argument
            for (token, value) in replacements {
                filled = filled.replacingOccurrences(of: token, with: value)
            }
            return filled
        }
    }

    /// What the preference should say, for showing back to somebody.
    public var text: String {
        arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }
}

/// Runs a `CredentialCommand` and reports what came back.
public enum CredentialRunner {
    public enum Outcome: Equatable {
        /// The one line the command printed, with the newline taken off.
        case password(String)
        /// It ran and said nothing. Not an error: a manager that has no entry
        /// for this host is a normal answer, and the system's own dialog is
        /// the right next step.
        case nothing
        /// It could not be run, took too long, or exited non-zero. The message
        /// is for a person to read and never contains what was on stdout.
        case failed(String)
    }

    /// - Parameter timeout: how long to wait. A password manager may need to
    ///   unlock, which is a human-speed operation, but a command that never
    ///   returns must not hang the window forever.
    public static func run(
        _ command: CredentialCommand,
        for share: URL,
        user: String? = nil,
        timeout: TimeInterval = 30
    ) -> Outcome {
        let arguments = command.arguments(for: share, user: user)
        guard let program = arguments.first else { return .failed("no command configured") }

        let process = Process()
        // A path, or a name looked up on PATH. execve either way — never a
        // shell.
        if program.contains("/") {
            process.executableURL = URL(fileURLWithPath: program)
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [program]
        }
        process.arguments = (process.arguments ?? []) + Array(arguments.dropFirst())

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        // Nothing to type into. A command that waits for input would otherwise
        // wait forever with no window to wait in.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failed("could not run \(program): \(error.localizedDescription)")
        }

        // Read on their own queues, and wait separately.
        //
        // readDataToEndOfFile blocks until the far end closes, which for a
        // process that is still running means until it exits. Doing that
        // before the wait made the timeout below unreachable: a command that
        // hung held the mount for as long as it liked, and the test that
        // proves otherwise is the only reason this is not still true.
        let collected = DispatchGroup()
        var stdout = Data()
        var stderr = Data()
        let buffers = DispatchQueue(label: "io.github.sapn95.pfadi.credential-output")

        for (pipe, isOut) in [(output, true), (errors, false)] {
            collected.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                buffers.sync {
                    if isOut { stdout = data } else { stderr = data }
                }
                collected.leave()
            }
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            // SIGTERM, then SIGKILL for anything that ignores it. A command
            // holding a Touch ID prompt open forever is exactly the case this
            // is for, and asking politely is not enough.
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            return .failed("\(program) did not answer within \(Int(timeout)) seconds")
        }

        // Bounded too: the pipes are closed by now, so this returns at once
        // unless something has inherited them, and waiting forever for a
        // grandchild is the other way to hang.
        _ = collected.wait(timeout: .now() + 5)
        let out = buffers.sync { stdout }
        let err = buffers.sync { stderr }

        guard process.terminationStatus == 0 else {
            let why = describe(err, hiding: out).map { ": \($0)" } ?? ""
            return .failed("\(program) exited \(process.terminationStatus)\(why)")
        }

        let password = String(decoding: out, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return password.isEmpty ? .nothing : .password(password)
    }

    /// The first line of what the command complained about, for a person.
    ///
    /// Redacted if the secret turns up in it. A tool that echoes the password
    /// it just printed would otherwise put it in the status line, and this is
    /// the one place that could happen.
    private static func describe(_ stderr: Data, hiding stdout: Data) -> String? {
        let secret = String(decoding: stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = String(decoding: stderr, as: UTF8.self)
            .split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)

        guard let text, !text.isEmpty else { return nil }
        guard secret.isEmpty || !text.contains(secret) else {
            return "it printed the password on its error output, which is not repeated here"
        }
        // Bounded, because an error line is a sentence and a wall of text in
        // the status bar helps nobody.
        return text.count > 160 ? String(text.prefix(160)) + "…" : text
    }
}
