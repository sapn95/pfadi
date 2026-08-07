import Foundation
import PfadiCore

/// The parts of `pfadi-default` that edit somebody's shell profile and their
/// LaunchServices preferences.
///
/// Both of those are files that were there before pfadi and will be there
/// after. Every check here is about giving them back exactly as they were.
enum DefaultHandlerSuites {
    static func run() {
        shellProfile()
        handlers()
    }

    private static func shellProfile() {
        Harness.suite("profile: the block goes in and comes back out cleanly") {
            let original = """
                export PATH=/usr/local/bin:$PATH
                alias ll='ls -la'
                """
            let withBlock =
                original + "\n\n" + DefaultHandler.shellBlock(command: "'/opt/homebrew/bin/pfadi'")
                + "\n"

            Harness.expect(
                withBlock.contains(DefaultHandler.markerStart), "the markers are there")
            Harness.expectEqual(
                DefaultHandler.removingBlock(from: withBlock).trimmingCharacters(
                    in: .whitespacesAndNewlines),
                original,
                "and undo leaves the rest of the profile alone")
        }

        Harness.suite("profile: removing a block that was never there changes nothing") {
            let untouched = "# just my own things\nexport EDITOR=vim\n"
            Harness.expectEqual(
                DefaultHandler.removingBlock(from: untouched), untouched,
                "somebody who never ran apply keeps their file byte for byte")
        }

        Harness.suite("profile: markers the wrong way round are left alone") {
            // A hand-edited profile can end up like this, and in Swift an
            // inverted range is not an empty one, it is a crash.
            let muddled = """
                \(DefaultHandler.markerEnd)
                open() { echo mine; }
                \(DefaultHandler.markerStart)
                """
            Harness.expectEqual(
                DefaultHandler.removingBlock(from: muddled), muddled,
                "refused rather than crashing in somebody's login shell")
        }

        Harness.suite("profile: a path with a quote in it cannot break out") {
            // The whole reason for shellQuoted: this text becomes a function in
            // somebody's login shell, and a path is data, not code.
            let nasty = "/Users/some'body/$(rm -rf ~)/Pfadi.app"
            let quoted = DefaultHandler.shellQuoted(nasty)
            Harness.expect(quoted.hasPrefix("'"), "it is quoted")
            Harness.expect(
                !quoted.contains("'$("),
                "and the substitution is inside quotes rather than live")
            Harness.expect(
                quoted.contains("'\\''"),
                "the embedded quote is closed, escaped and reopened")

            // What the shell itself makes of it, which is the only opinion that
            // counts.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf %s \(quoted)"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            Harness.expectEqual(
                String(decoding: data, as: UTF8.self), nasty,
                "and /bin/sh reads back exactly the path we gave it")
        }

        Harness.suite("profile: the function only takes over one folder argument") {
            let block = DefaultHandler.shellBlock(command: "'/opt/homebrew/bin/pfadi'")
            Harness.expect(
                block.contains("[ $# -eq 1 ]") && block.contains("[ -d \"$1\" ]"),
                "so open report.pdf and open -a Safari are untouched")
            Harness.expect(
                block.contains("command open \"$@\""),
                "and everything else reaches the real open")
        }
    }

    private static func handlers() {
        Harness.suite("handlers: an entry is added when there is none") {
            let updated = DefaultHandler.setting(
                [], contentType: "public.folder", to: "io.github.sapn95.pfadi")
            Harness.expectEqual(
                DefaultHandler.handler(in: updated, for: "public.folder"),
                "io.github.sapn95.pfadi",
                "the list now points at pfadi")
            Harness.expectEqual(updated.count, 1, "and there is exactly one of it")
        }

        Harness.suite("handlers: an existing entry is edited, not replaced") {
            // Entries carry keys we do not care about. Dropping them because
            // we only wanted one would quietly change unrelated behaviour.
            let existing: [[String: Any]] = [
                [
                    "LSHandlerContentType": "public.folder",
                    "LSHandlerRoleAll": "com.apple.finder",
                    "LSHandlerPreferredVersions": ["LSHandlerRoleAll": "-"],
                ]
            ]
            let updated = DefaultHandler.setting(
                existing, contentType: "public.folder", to: "io.github.sapn95.pfadi")
            Harness.expectEqual(updated.count, 1, "still one entry")
            Harness.expectEqual(
                DefaultHandler.handler(in: updated, for: "public.folder"),
                "io.github.sapn95.pfadi", "pointing at pfadi")
            Harness.expect(
                updated[0]["LSHandlerPreferredVersions"] != nil,
                "with the keys we know nothing about left where they were")
        }

        Harness.suite("handlers: unrelated types are never touched") {
            let existing: [[String: Any]] = [
                ["LSHandlerContentType": "public.html", "LSHandlerRoleAll": "com.apple.Safari"]
            ]
            let updated = DefaultHandler.setting(
                existing, contentType: "public.folder", to: "io.github.sapn95.pfadi")
            Harness.expectEqual(
                DefaultHandler.handler(in: updated, for: "public.html"), "com.apple.Safari",
                "somebody's browser choice survives")
            Harness.expectEqual(updated.count, 2, "and the new entry is added beside it")
        }

        Harness.suite("handlers: undo removes ours and only ours") {
            let mine = DefaultHandler.setting(
                [], contentType: "public.folder", to: "io.github.sapn95.pfadi")
            Harness.expectEqual(
                DefaultHandler.removing(
                    mine, contentType: "public.folder", ownedBy: "io.github.sapn95.pfadi"
                ).count,
                0,
                "an entry that was nothing but ours goes away entirely")

            let somebodyElse: [[String: Any]] = [
                [
                    "LSHandlerContentType": "public.folder",
                    "LSHandlerRoleAll": "com.binarynights.ForkLift",
                ]
            ]
            Harness.expectEqual(
                DefaultHandler.handler(
                    in: DefaultHandler.removing(
                        somebodyElse, contentType: "public.folder",
                        ownedBy: "io.github.sapn95.pfadi"),
                    for: "public.folder"),
                "com.binarynights.ForkLift",
                "another browser's entry is somebody's own decision, left alone")
        }

        Harness.suite("handlers: undo keeps an entry that has more in it than us") {
            let shared: [[String: Any]] = [
                [
                    "LSHandlerContentType": "public.folder",
                    "LSHandlerRoleAll": "io.github.sapn95.pfadi",
                    "LSHandlerRoleViewer": "com.apple.finder",
                ]
            ]
            let cleaned = DefaultHandler.removing(
                shared, contentType: "public.folder", ownedBy: "io.github.sapn95.pfadi")
            Harness.expectEqual(cleaned.count, 1, "the entry stays")
            Harness.expect(
                cleaned[0]["LSHandlerRoleAll"] == nil,
                "with our key gone")
            Harness.expect(
                cleaned[0]["LSHandlerRoleViewer"] != nil,
                "and the viewer role somebody else set still there")
        }

        Harness.suite("handlers: the keys are the ones macOS actually reads") {
            // Spelled out because a typo here is silent: the write succeeds,
            // the file gains an entry nothing looks at, and status reports it
            // back to us as though it meant something.
            Harness.expectEqual(DefaultHandler.handlersKey, "LSHandlers", "the array")
            Harness.expectEqual(
                DefaultHandler.contentTypeKey, "LSHandlerContentType", "the type key")
            Harness.expectEqual(DefaultHandler.roleAllKey, "LSHandlerRoleAll", "the role key")
            Harness.expectEqual(DefaultHandler.fileViewerKey, "NSFileViewer", "the file viewer")
            Harness.expectEqual(
                DefaultHandler.launchServicesDomain,
                "com.apple.LaunchServices/com.apple.launchservices.secure",
                "and the preference domain")
        }
    }
}
