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
        /// Anything already at a destination that was trashed to make room.
        public let displaced: [(original: URL, inTrash: URL)]
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
            var failed: [(URL, String)] = []
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
                    case .replace:
                        // To the trash, never removeItem. A wrong answer in a
                        // replace dialog is then still recoverable.
                        if fileManager.fileExists(atPath: item.destination.path),
                            let trashed = try? FileOperations.trash(
                                item.destination, fileManager: fileManager)
                        {
                            displaced.append((item.destination, trashed))
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
                        moved.append((item.source, destination))
                    }
                } catch {
                    failed.append((item.source, error.localizedDescription))
                }
                done += item.size
            }

            let outcome = Outcome(
                created: created,
                moved: moved,
                displaced: displaced,
                skipped: skipped,
                failed: failed,
                cancelled: cancelled.isSet
            )
            DispatchQueue.main.async { completion(outcome) }
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
