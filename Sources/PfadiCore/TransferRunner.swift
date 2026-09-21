import Foundation

/// Carries out a plan, on a background queue, and can be stopped.
public final class TransferRunner {
    public struct Progress: Sendable {
        public let done: Int64
        public let total: Int64
        public let currentName: String

        public var fraction: Double {
            total > 0 ? Double(done) / Double(total) : 0
        }
    }

    public struct Outcome: Sendable {
        /// What was created, newest last. Undo walks this backwards.
        public let created: [URL]
        /// Sources that were moved, and where they came from.
        public let moved: [(from: URL, to: URL)]
        /// Source folders removed once their contents had gone, deepest first.
        /// Undo puts these back before moving anything into them.
        public let emptiedSources: [URL]
        /// Anything already at a destination that was trashed to make room.
        public let displaced: [(original: URL, inTrash: URL)]
        /// Anything already at a destination that had to be removed outright to
        /// make room, because its volume has no trash. Nothing can put these
        /// back, which is why they are counted apart from `displaced`.
        public let replacedForGood: [URL]
        public let skipped: Int
        public let failed: [(URL, String)]
        public let cancelled: Bool
    }

    private let queue = DispatchQueue(label: "io.github.sapn95.pfadi.transfer", qos: .userInitiated)
    private let cancelled = Cancellation()

    public init() {}

    public func cancel() { cancelled.set() }

    /// Runs `plan`, reporting progress on the main queue.
    ///
    /// `resolution` is asked for once per colliding top-level item, before any
    /// work starts, so nobody is answering dialogs halfway through a copy.
    public func run(
        _ plan: Transfer.Plan,
        resolutions: [URL: Transfer.Resolution],
        fileManager: FileManager = .default,
        progress: @escaping @Sendable (Progress) -> Void,
        completion: @escaping @Sendable (Outcome) -> Void
    ) {
        queue.async { [cancelled] in
            var created: [URL] = []
            var moved: [(from: URL, to: URL)] = []
            var displaced: [(original: URL, inTrash: URL)] = []
            var replacedForGood: [URL] = []
            var failed: [(URL, String)] = []
            var movedDirectories: [URL] = []
            var emptied: [URL] = []
            var skipped = 0
            var done: Int64 = 0

            // Destinations under a skipped item are skipped too: half a folder
            // is worse than none of it.
            var skippedRoots: [URL] = []

            for item in plan.items {
                if cancelled.isSet { break }

                if skippedRoots.contains(where: { Transfer.isAncestor($0, of: item.destination) }) {
                    skipped += 1
                    continue
                }

                var destination = item.destination
                if let resolution = resolutions[item.destination] {
                    switch resolution {
                    case .skip:
                        skipped += 1
                        skippedRoots.append(item.destination)
                        continue
                    case .keepBoth:
                        let folder = item.destination.deletingLastPathComponent()
                        destination = folder.appendingPathComponent(
                            Transfer.keepBothName(
                                for: item.destination, in: folder, fileManager: fileManager))
                    case .replace where item.source.path == item.destination.path:
                        // Duplicating a file into the folder it is already in
                        // collides with itself. Replace would trash the source
                        // and then copy from the trash, so it becomes the only
                        // answer that makes sense.
                        let folder = item.destination.deletingLastPathComponent()
                        destination = folder.appendingPathComponent(
                            Transfer.keepBothName(
                                for: item.destination, in: folder, fileManager: fileManager))

                    case .replace:
                        switch Self.makeRoom(at: item.destination, fileManager: fileManager) {
                        case .nothingThere:
                            break
                        case .trashed(let landed):
                            // No landing place means it went and the system did
                            // not say where, which undo cannot act on either
                            // way. It is not counted as replaced for good: the
                            // old one is in a trash somebody can go and look in.
                            if let landed { displaced.append((item.destination, landed)) }
                        case .removedForGood:
                            replacedForGood.append(item.destination)
                        case .refused(let why):
                            // Still in the way, so the copy below would fail on
                            // it anyway, with "File exists" instead of the
                            // reason. Everything underneath it goes too: the
                            // answer was given once, for the folder, and files
                            // copied into a folder that was meant to be replaced
                            // are a merge nobody asked for.
                            failed.append((item.source, why))
                            skippedRoots.append(item.destination)
                            continue
                        }
                    }
                }

                DispatchQueue.main.async {
                    progress(
                        Progress(
                            done: done, total: plan.totalBytes,
                            currentName: item.source.lastPathComponent))
                }

                do {
                    try Self.perform(
                        item, to: destination, kind: plan.kind, fileManager: fileManager)
                    created.append(destination)
                    if plan.kind == .move {
                        // A folder is recreated rather than moved, so its
                        // source is dealt with at the end once it is empty.
                        if item.isDirectory {
                            movedDirectories.append(item.source)
                        } else {
                            moved.append((item.source, destination))
                        }
                    }
                } catch {
                    failed.append((item.source, error.localizedDescription))
                }
                done += item.size
            }

            // A move that recreates folders and moves the files out of them
            // leaves the folders behind, empty. Deepest first, and only when
            // really empty: a skipped or failed file inside one means it is
            // still somebody's data and removeItem would take it with it.
            for folder in movedDirectories.sorted(by: {
                $0.pathComponents.count > $1.pathComponents.count
            }) {
                let contents = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
                guard contents.isEmpty else { continue }
                do {
                    try fileManager.removeItem(at: folder)
                    emptied.append(folder)
                } catch {
                    // Said rather than swallowed. Everything inside the folder
                    // moved and the empty folder stayed, which looks exactly
                    // like a move that half worked, because it is one.
                    failed.append((folder, error.localizedDescription))
                }
            }

            let outcome = Outcome(
                created: created,
                moved: moved,
                emptiedSources: emptied,
                displaced: displaced,
                replacedForGood: replacedForGood,
                skipped: skipped,
                failed: failed,
                cancelled: cancelled.isSet
            )
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// What became of something that was in the way of a replacement.
    private enum Displacement {
        /// Nothing was there.
        case nothingThere
        /// It went to the trash, with where it landed when the system said.
        case trashed(URL?)
        /// There is no trash on that volume, so it was removed and nothing can
        /// put it back.
        case removedForGood
        /// It is still there, with the reason it could not be got out of the way.
        case refused(String)
    }

    /// Clears a destination so a replacement can be written where it was.
    ///
    /// This has to happen for Replace to mean anything: `copyfile` refuses a
    /// destination that already exists and so does `rename(2)`, so leaving the
    /// old one there turned Replace on a share into "File exists" with nothing
    /// replaced at all.
    ///
    /// The trash where there is one, because a wrong answer in a replace dialog
    /// should be recoverable, and removing it outright where there is none,
    /// which is every share. Which of the two it is gets asked rather than found
    /// out by failing: a trash that exists and refuses this one item is not a
    /// reason to destroy what somebody was replacing, so that comes back as a
    /// refusal and the item is left where it is.
    private static func makeRoom(at destination: URL, fileManager: FileManager) -> Displacement {
        guard fileManager.fileExists(atPath: destination.path) else { return .nothingThere }

        if FileOperations.hasTrash(for: destination, fileManager: fileManager) {
            // The checked call: macOS refuses the folders it keeps in a home
            // directory by reporting success and doing nothing, and a replace
            // that believed that would report the old one as recoverable.
            switch FileOperations.trashChecking(destination, fileManager: fileManager) {
            case .moved(let landed): return .trashed(landed)
            case .refused(let why): return .refused(why)
            }
        }

        do {
            try fileManager.removeItem(at: destination)
            return .removedForGood
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    private static func perform(
        _ item: Transfer.Item,
        to destination: URL,
        kind: Transfer.Kind,
        fileManager: FileManager
    ) throws {
        if item.isDirectory {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            return
        }

        if kind == .move {
            // rename(2) when both sides are on one volume, which is instant and
            // atomic. Across volumes it fails and the copy below is the answer.
            do {
                try fileManager.moveItem(at: item.source, to: destination)
                return
            } catch {
                try Self.clone(item.source, to: destination)
                try fileManager.removeItem(at: item.source)
                return
            }
        }

        try Self.clone(item.source, to: destination)
    }

    /// `copyfile` with COPYFILE_CLONE rather than FileManager.
    ///
    /// On APFS a clone is a constant-time copy that shares blocks until one
    /// side is written to, so duplicating twenty gigabytes costs nothing and no
    /// disk space. It degrades to an ordinary copy anywhere it cannot clone,
    /// and COPYFILE_CLONE carries the extended attributes, ACLs and flags that
    /// a naive read-and-write copy silently drops.
    private static func clone(_ source: URL, to destination: URL) throws {
        let status = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                copyfile(from, to, nil, copyfile_flags_t(COPYFILE_CLONE))
            }
        }
        guard status == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
    }
}

/// A flag that can be set from one thread and read from another.
private final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
