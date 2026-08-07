import Foundation

/// How much is inside a folder.
///
/// The filesystem does not know. A folder's own size is the size of its
/// directory record, which is why every file browser that shows a real number
/// here has walked the tree to get it, and why Finder leaves the column empty
/// until you ask. Walking a large tree takes seconds, so nothing here may ever
/// run where a person is waiting for it.
public enum FolderSize {
    public struct Measurement: Equatable, Sendable {
        /// How much is in it, logical rather than allocated.
        ///
        /// Allocated was the first answer, and it was wrong twice over. A
        /// cloud placeholder has no blocks on disk at all, so a OneDrive
        /// folder holding 253 KB across four files measured as zero — true,
        /// and no use to anybody. And the file rows have always shown the
        /// logical size, so the same column meant two different things
        /// depending on which kind of row you were looking at.
        public let bytes: Int64
        /// How many files went into it.
        public let files: Int
        /// False when the walk stopped early, at the limit or because the
        /// folder stopped being interesting. The number is then a floor, not
        /// an answer, and has to be shown as one.
        public let complete: Bool

        public init(bytes: Int64, files: Int, complete: Bool) {
            self.bytes = bytes
            self.files = files
            self.complete = complete
        }
    }

    /// Adds up everything under `url`.
    ///
    /// - Parameters:
    ///   - limit: how many entries to visit before giving up. A folder with
    ///     more than this is reported as "over" whatever was counted so far,
    ///     which is more useful than a spinner that never stops.
    ///   - isCancelled: asked regularly. Scrolling past a folder while it is
    ///     being measured should stop the walk, not wait for it.
    public static func measure(
        _ url: URL,
        limit: Int = 200_000,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { false }
    ) -> Measurement {
        // Asked before walking, because `enumerator(at:)` hands back a working
        // enumerator for a path that is not there and then yields nothing. The
        // difference matters: an empty folder is zero bytes, and a folder that
        // has been deleted underneath us is not a number at all.
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return Measurement(bytes: 0, files: 0, complete: false) }

        let keys: Set<URLResourceKey> = [
            .totalFileSizeKey, .fileSizeKey, .isRegularFileKey,
        ]
        // Symbolic links are not followed by default, which is what keeps a
        // link back up the tree from making this run forever. Package contents
        // are counted: an .app really does take up that much room.
        let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }  // an unreadable subfolder is skipped, not fatal
        )
        guard let enumerator else { return Measurement(bytes: 0, files: 0, complete: false) }

        var bytes: Int64 = 0
        var files = 0
        var visited = 0
        // A file whose size could not be read counts as nothing, which
        // understates the total. Saying so turns the answer into "over", which
        // is the honest shape for a floor.
        var unreadable = false

        for case let child as URL in enumerator {
            visited += 1
            // Every so often rather than every entry: reading a flag through a
            // lock a hundred thousand times costs more than the walk.
            if visited % 512 == 0, isCancelled() {
                return Measurement(bytes: bytes, files: files, complete: false)
            }
            if visited > limit {
                return Measurement(bytes: bytes, files: files, complete: false)
            }

            guard let values = try? child.resourceValues(forKeys: keys),
                values.isRegularFile == true
            else { continue }
            // totalFileSize includes resource forks; fileSize is the fallback
            // when the volume cannot say. Both are what the file *is*, which
            // is the number a cloud provider can still answer for something it
            // has not downloaded.
            guard let size = values.totalFileSize ?? values.fileSize else {
                unreadable = true
                files += 1
                continue
            }
            bytes += Int64(size)
            files += 1
        }
        return Measurement(
            bytes: bytes, files: files, complete: !unreadable && !isCancelled())
    }
}

/// Measures folders one at a time, only the ones somebody can actually see.
///
/// The list asks for the rows on screen; scrolling asks again with a different
/// set. Anything no longer wanted is dropped from the queue, and the walk in
/// flight is told to stop. Results are cached, so scrolling back is instant and
/// a folder is never walked twice for the same window.
public final class FolderSizeQueue {
    /// Called on the main queue, once per folder, as each measurement lands.
    public var onMeasured: ((URL, FolderSize.Measurement) -> Void)?

    private let limit: Int
    private let queue: DispatchQueue
    private let deliver: (@escaping () -> Void) -> Void

    private let lock = NSLock()
    private var cache: [String: FolderSize.Measurement] = [:]
    private var pending: [URL] = []
    private var inFlight: URL?
    private var running = false

    public init(
        limit: Int = 200_000,
        queue: DispatchQueue = DispatchQueue(
            label: "io.github.sapn95.pfadi.folder-size", qos: .utility),
        deliver: @escaping (@escaping () -> Void) -> Void = { work in
            DispatchQueue.main.async(execute: work)
        }
    ) {
        self.limit = limit
        self.queue = queue
        self.deliver = deliver
    }

    /// The folders worth knowing about right now, nearest the top first.
    ///
    /// Replaces the queue rather than adding to it: rows that scrolled away are
    /// no longer worth the disk they cost.
    public func want(_ urls: [URL]) {
        lock.lock()
        let wanted = urls.filter { cache[$0.path] == nil }
        // The walk in flight has to be let go of when it is no longer wanted.
        // Clearing it is exactly what the cancellation closure in `step`
        // watches for, so leaving it set meant a folder scrolled past went on
        // being walked to the end.
        if let current = inFlight, !wanted.contains(where: { $0.path == current.path }) {
            inFlight = nil
        }
        // And whatever is still in flight is not queued a second time, or it
        // would be measured twice and reported twice.
        pending = wanted.filter { $0.path != inFlight?.path }
        let start = !running && !pending.isEmpty
        if start { running = true }
        lock.unlock()

        if start { step() }
    }

    /// What is known about a folder, if it has been measured.
    public func cached(_ url: URL) -> FolderSize.Measurement? {
        lock.lock()
        defer { lock.unlock() }
        return cache[url.path]
    }

    /// Throws the answers away, for when the contents may have changed.
    ///
    /// Not called on every reload: the watcher fires whenever anything in the
    /// folder is written, and re-walking a large tree on every save would make
    /// the column cost more than it is worth.
    public func forget() {
        lock.lock()
        cache.removeAll()
        pending.removeAll()
        // The walk in flight goes too. Without this it finishes and writes its
        // answer into the cache that was just emptied, so ⌘R on a folder being
        // measured put the stale number straight back.
        inFlight = nil
        lock.unlock()
    }

    /// Stops the queue and the walk in flight. Kept results stay.
    public func cancelPending() {
        lock.lock()
        pending.removeAll()
        inFlight = nil
        lock.unlock()
    }

    private func step() {
        lock.lock()
        guard !pending.isEmpty else {
            running = false
            inFlight = nil
            lock.unlock()
            return
        }
        let next = pending.removeFirst()
        inFlight = next
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let measurement = FolderSize.measure(next, limit: limit) { [weak self] in
                guard let self else { return true }
                lock.lock()
                defer { lock.unlock() }
                // Still the one we were asked for? A newer `want` that does not
                // include it has already moved on.
                return inFlight?.path != next.path
            }

            lock.lock()
            let stillWanted = inFlight?.path == next.path
            // A partial number from a cancelled walk is not cached: the next
            // time this folder scrolls into view it deserves a real answer.
            if stillWanted { cache[next.path] = measurement }
            lock.unlock()

            if stillWanted {
                deliver { [weak self] in self?.onMeasured?(next, measurement) }
            }
            step()
        }
    }
}
