import Foundation

/// Tells you when a directory changed underneath you.
///
/// A file browser that shows a stale listing is worse than one that shows
/// nothing: it looks authoritative and is wrong. Anything the shell, a build
/// tool or another application does has to arrive without pressing ⌘R.
///
/// Built on a dispatch source rather than FSEvents. It watches one directory,
/// which is exactly the scope here, and needs no stream, no run loop
/// scheduling and no event-id bookkeeping.
public final class DirectoryWatcher {
    private let url: URL
    private let queue: DispatchQueue
    private let debounce: DispatchTimeInterval
    private let onChange: () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    /// - Parameters:
    ///   - debounce: how long to wait for the noise to stop. Unpacking an
    ///     archive fires hundreds of events; reloading once at the end is both
    ///     cheaper and less jarring than reloading per file.
    public init(
        url: URL,
        queue: DispatchQueue = .main,
        debounce: DispatchTimeInterval = .milliseconds(200),
        onChange: @escaping () -> Void
    ) {
        self.url = url
        self.queue = queue
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit {
        pending?.cancel()
        source?.cancel()
    }

    /// Starts watching. Returns false when the directory cannot be opened,
    /// which is not worth an error: the caller is about to fail to list it too.
    @discardableResult
    public func start() -> Bool {
        stop()

        // O_EVTONLY asks for notifications without claiming the file is open
        // for reading, so an unmount is not blocked by this process.
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        return true
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
