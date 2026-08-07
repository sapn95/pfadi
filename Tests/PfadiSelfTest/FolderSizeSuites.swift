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
