import Foundation

/// The parts of "use pfadi instead of Finder" that are text and data rather
/// than system calls.
///
/// Split out of the `pfadi-default` command so they can be tested. Every one of
/// these edits somebody's shell profile or their LaunchServices preferences,
/// which is exactly the kind of code that must not be discovered to be wrong
/// after it has run.
public enum DefaultHandler {
    /// The global preference that decides what "Finder" means to AppKit.
    ///
    /// `NSWorkspace.selectFile(_:inFileViewerRootedAtPath:)` — the call behind
    /// "Show in Finder", "Reveal in Finder" and "Show in Enclosing Folder" in
    /// other applications — reads this user default and, when it holds a bundle
    /// identifier of an application that is registered, hands the file to that
    /// application instead of to Finder. Undocumented on the current pages,
    /// present since Mac OS X 10.4, and the mechanism Path Finder and ForkLift
    /// both use.
    ///
    /// This is the one part of replacing Finder that genuinely works, and it is
    /// worth more than the rest put together: it is how the browser you chose
    /// gets to answer when some other application says "show me where this is".
    public static let fileViewerKey = "NSFileViewer"

    /// Where LaunchServices keeps which application opens what.
    ///
    /// Written directly because the API that ought to do it will not: see
    /// `refusedByLaunchServices`.
    public static let launchServicesDomain =
        "com.apple.LaunchServices/com.apple.launchservices.secure"
    public static let handlersKey = "LSHandlers"
    public static let contentTypeKey = "LSHandlerContentType"
    public static let roleAllKey = "LSHandlerRoleAll"

    /// paramErr. What `LSSetDefaultRoleHandlerForContentType` returns for a
    /// content type it will not reassign, which includes every type meaning
    /// "a folder".
    public static let refusedByLaunchServices: Int32 = -50

    // MARK: - The shell function

    public static let markerStart = "# >>> pfadi instead of finder >>>"
    public static let markerEnd = "# <<< pfadi instead of finder <<<"

    /// A string safe to drop into shell source.
    ///
    /// Single quotes, with any single quote in the value closed, escaped and
    /// reopened. A path is somebody else's data: it can hold a quote, a dollar
    /// or a backtick, and this text becomes a function in their profile.
    public static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The block written into `.zshrc`, wrapped in its markers.
    ///
    /// `open` is overridden rather than aliased so that the decision can be
    /// made per call: one argument that is a folder goes to pfadi, everything
    /// else goes to the real `open`, so `open report.pdf` and `open -a Safari`
    /// keep working exactly as before.
    public static func shellBlock(command: String) -> String {
        """
        \(markerStart)
        # `open .` and `open <folder>` go to pfadi. Everything else is untouched,
        # so `open report.pdf` still opens whatever owns a PDF.
        open() {
          if [ $# -eq 1 ] && [ -d "$1" ]; then
            command \(command) "$1"
          else
            command open "$@"
          fi
        }
        \(markerEnd)
        """
    }

    /// Cuts our block back out of a profile, leaving everything else alone.
    ///
    /// The whole point of the markers: somebody's shell profile is theirs, and
    /// `undo` has to give it back byte for byte apart from what we added.
    public static func removingBlock(from text: String) -> String {
        guard let start = text.range(of: markerStart),
            let end = text.range(of: markerEnd)
        else { return text }
        var cut = text
        // Through the end of the marker line, and the newline after it.
        let upTo =
            text.index(end.upperBound, offsetBy: 1, limitedBy: text.endIndex) ?? end.upperBound
        cut.removeSubrange(start.lowerBound..<upTo)
        return cut
    }

    // MARK: - The LaunchServices handler list

    /// Points `contentType` at `bundleID`, keeping everything else as it was.
    ///
    /// An existing entry is edited rather than replaced: entries carry other
    /// keys — a viewer role, a preferred version — and dropping those because
    /// we only care about one of them would quietly change unrelated behaviour.
    public static func setting(
        _ handlers: [[String: Any]],
        contentType: String,
        to bundleID: String
    ) -> [[String: Any]] {
        var updated = handlers
        if let index = updated.firstIndex(where: { $0[contentTypeKey] as? String == contentType }) {
            updated[index][roleAllKey] = bundleID
            return updated
        }
        updated.append([contentTypeKey: contentType, roleAllKey: bundleID])
        return updated
    }

    /// Undoes exactly what `setting` did, and only when it was us.
    ///
    /// An entry pointing somewhere else was somebody's own choice, or another
    /// application's, and is left alone. An entry that becomes nothing but a
    /// content type is removed rather than left as a stub.
    public static func removing(
        _ handlers: [[String: Any]],
        contentType: String,
        ownedBy bundleID: String
    ) -> [[String: Any]] {
        var updated: [[String: Any]] = []
        for entry in handlers {
            guard entry[contentTypeKey] as? String == contentType,
                entry[roleAllKey] as? String == bundleID
            else {
                updated.append(entry)
                continue
            }
            var stripped = entry
            stripped.removeValue(forKey: roleAllKey)
            // Nothing left but the type it was about, so there is nothing to
            // keep.
            if stripped.count > 1 { updated.append(stripped) }
        }
        return updated
    }

    /// Who the list says opens `contentType`, if anybody.
    public static func handler(
        in handlers: [[String: Any]],
        for contentType: String
    ) -> String? {
        handlers
            .first { $0[contentTypeKey] as? String == contentType }?[roleAllKey] as? String
    }
}
