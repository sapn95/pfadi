import Foundation
import PfadiCore

/// Folder sizes: the measurement itself, and the queue that keeps it off the
/// main thread and away from folders nobody is looking at.
enum FolderSizeSuites {
    static func run() {
        measuring()
        queueing()
    }

    private static func measuring() {
        Harness.suite("folder size: everything underneath, not just the top") {
            try withSandbox(["top.txt", "sub"], directories: ["sub"]) { root in
                try Data(repeating: 0x61, count: 4096)
                    .write(to: root.appendingPathComponent("sub/deep.bin"))

                let measured = FolderSize.measure(root)
                Harness.expectEqual(measured.files, 2, "both files counted, however deep")
                Harness.expect(measured.complete, "a small folder is measured completely")
                Harness.expect(
                    measured.bytes >= 4096,
                    "at least the 4 KB that was written, got \(measured.bytes)")
            }
        }

        Harness.suite("folder size: a folder agrees with the rows inside it") {
            // The two used to disagree. A file row shows its logical size; the
            // folder summed allocated size, which for a OneDrive placeholder
            // is zero because there are no blocks on disk. A folder holding
            // 253 KB across four files read as Zero KB.
            try withSandbox(["one.bin", "two.bin"]) { root in
                try Data(repeating: 0x61, count: 3_000).write(
                    to: root.appendingPathComponent("one.bin"))
                try Data(repeating: 0x62, count: 5_000).write(
                    to: root.appendingPathComponent("two.bin"))

                let rows = try DirectoryListing.read(
                    root, showHidden: true, columns: [.name, .size])
                let fromRows = rows.compactMap(\.size).reduce(0, +)
                Harness.expectEqual(
                    FolderSize.measure(root).bytes, fromRows,
                    "the column means one thing whichever kind of row it is on")
                Harness.expectEqual(fromRows, 8_000, "and that thing is what was written")
            }
        }

        Harness.suite("folder size: an empty folder is zero, not unknown") {
            try withSandbox([]) { root in
                let measured = FolderSize.measure(root)
                Harness.expectEqual(measured.bytes, 0, "nothing in it is nothing")
                Harness.expectEqual(measured.files, 0, "and no files")
                Harness.expect(measured.complete, "which is a complete answer")
            }
        }

        Harness.suite("folder size: hidden files count, because they take up room") {
            try withSandbox([".hidden"]) { root in
                Harness.expectEqual(
                    FolderSize.measure(root).files, 1,
                    "a dotfile is still a file on the disk")
            }
        }

        Harness.suite("folder size: the limit reports a floor rather than a total") {
            try withSandbox(["a.txt", "b.txt", "c.txt", "d.txt"]) { root in
                let measured = FolderSize.measure(root, limit: 2)
                Harness.expect(
                    !measured.complete,
                    "stopping early is reported, so the column can say 'over'")
                Harness.expect(measured.files < 4, "and it really did stop")
            }
        }

        Harness.suite("folder size: cancelling stops the walk") {
            try withSandbox((0..<40).map { "file-\($0).txt" }) { root in
                let measured = FolderSize.measure(root, isCancelled: { true })
                Harness.expect(
                    !measured.complete,
                    "a cancelled walk never claims to be an answer")
            }
        }

        Harness.suite("folder size: a folder that is not there does not throw") {
            let missing = URL(fileURLWithPath: "/nope-\(UUID().uuidString)")
            let measured = FolderSize.measure(missing)
            Harness.expectEqual(measured.bytes, 0, "nothing to add up")
            Harness.expect(!measured.complete, "and it says so rather than reporting zero bytes")
        }
    }

    private static func queueing() {
        Harness.suite("folder size queue: measures what was asked for, once") {
            try withSandbox(["one", "two"], directories: ["one", "two"]) { root in
                try Data(repeating: 0x61, count: 512)
                    .write(to: root.appendingPathComponent("one/a.bin"))

                // Delivered inline rather than through the main queue: this
                // test has no run loop to turn, and what is being checked is
                // the scheduling, not GCD.
                let queue = FolderSizeQueue(deliver: { $0() })
                let done = DispatchSemaphore(value: 0)
                var measured: [String: FolderSize.Measurement] = [:]
                let lock = NSLock()

                queue.onMeasured = { url, measurement in
                    lock.lock()
                    measured[url.lastPathComponent] = measurement
                    let finished = measured.count == 2
                    lock.unlock()
                    if finished { done.signal() }
                }
                queue.want([
                    root.appendingPathComponent("one"), root.appendingPathComponent("two"),
                ])

                Harness.expect(
                    done.wait(timeout: .now() + 10) == .success,
                    "both folders came back")
                lock.lock()
                let one = measured["one"]
                let two = measured["two"]
                lock.unlock()
                Harness.expect((one?.bytes ?? 0) >= 512, "the one with a file in it has bytes")
                Harness.expectEqual(two?.bytes, 0, "and the empty one has none")

                Harness.expectEqual(
                    queue.cached(root.appendingPathComponent("one"))?.bytes, one?.bytes,
                    "the answer is kept, so scrolling back is free")
            }
        }

        Harness.suite("folder size queue: forgetting really forgets") {
            try withSandbox(["sub"], directories: ["sub"]) { root in
                let queue = FolderSizeQueue(deliver: { $0() })
                let done = DispatchSemaphore(value: 0)
                queue.onMeasured = { _, _ in done.signal() }
                queue.want([root.appendingPathComponent("sub")])
                _ = done.wait(timeout: .now() + 10)

                Harness.expect(
                    queue.cached(root.appendingPathComponent("sub")) != nil, "measured first")
                queue.forget()
                Harness.expect(
                    queue.cached(root.appendingPathComponent("sub")) == nil,
                    "and gone after ⌘R, so a stale size can be corrected")
            }
        }

        Harness.suite("folder size queue: forgetting mid-walk does not put it back") {
            // A big enough tree that the walk is still running when forget()
            // lands. Without clearing what is in flight, it finished and wrote
            // its answer into the cache that had just been emptied, so ⌘R on a
            // folder being measured put the stale number straight back.
            try withSandbox(["big"], directories: ["big"]) { root in
                let big = root.appendingPathComponent("big")
                for index in 0..<4000 {
                    try Data("x".utf8).write(to: big.appendingPathComponent("f\(index).txt"))
                }
                let queue = FolderSizeQueue(deliver: { $0() })
                queue.want([big])
                queue.forget()

                // Long enough for a walk that was not stopped to have finished.
                Thread.sleep(forTimeInterval: 1.5)
                Harness.expect(
                    queue.cached(big) == nil,
                    "nothing came back after being forgotten")
            }
        }

        Harness.suite("folder size queue: what is in flight is not queued again") {
            try withSandbox(["one"], directories: ["one"]) { root in
                let one = root.appendingPathComponent("one")
                let queue = FolderSizeQueue(deliver: { $0() })
                var arrivals = 0
                let lock = NSLock()
                queue.onMeasured = { _, _ in
                    lock.lock()
                    arrivals += 1
                    lock.unlock()
                }
                // The same folder asked for twice, which is what every scroll
                // event does for the rows that did not move.
                queue.want([one])
                queue.want([one])
                Thread.sleep(forTimeInterval: 1)
                lock.lock()
                let seen = arrivals
                lock.unlock()
                Harness.expectEqual(seen, 1, "measured once, reported once")
            }
        }

        Harness.suite("folder size queue: asking for nothing is not an error") {
            let queue = FolderSizeQueue(deliver: { $0() })
            queue.onMeasured = { _, _ in
                Harness.expect(false, "nothing was asked for, so nothing should arrive")
            }
            queue.want([])
            queue.cancelPending()
            Harness.expect(true, "an empty list leaves the queue idle")
        }
    }
}

extension FolderSizeSuites {
    /// A total that had to guess is a floor, not an answer.
    static func runIncomplete() {
        Harness.suite("folder size: a file whose size cannot be read makes it a floor") {
            try withSandbox([]) { root in
                // A broken symbolic link is counted as an entry the walk saw
                // and could not weigh. Adding nothing for it and still calling
                // the total complete understates it while claiming it is exact.
                try Data(repeating: 0x61, count: 2_000).write(
                    to: root.appendingPathComponent("real.bin"))
                try FileManager.default.createSymbolicLink(
                    at: root.appendingPathComponent("dangling"),
                    withDestinationURL: root.appendingPathComponent("gone.bin"))

                let measured = FolderSize.measure(root)
                Harness.expect(measured.bytes >= 2_000, "what could be weighed is in the total")
                // Whether a dangling link is reported as a regular file at all
                // is the filesystem's business; what matters is that if it is
                // counted, the total stops claiming to be exact.
                Harness.expect(
                    measured.files == 1 || !measured.complete,
                    "either it was not counted, or the total says it is a floor")
            }
        }
    }
}
