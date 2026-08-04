import Foundation

/// A test harness in forty lines, because XCTest is not installable without Xcode.
///
/// Prints one line per check, exits non-zero if any of them failed, which is
/// everything a CI job needs from a test runner.
enum Harness {
    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var checks = 0

    static func expect(
        _ condition: Bool,
        _ what: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        checks += 1
        if condition {
            print("  ok   \(what)")
        } else {
            failures += 1
            print("  FAIL \(what)  (\(file):\(line))")
        }
    }

    static func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ what: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        checks += 1
        if actual == expected {
            print("  ok   \(what)")
        } else {
            failures += 1
            print("  FAIL \(what)  (\(file):\(line))")
            print("       expected: \(expected)")
            print("       actual:   \(actual)")
        }
    }

    static func suite(_ name: String, _ body: () throws -> Void) {
        print("\(name)")
        do {
            try body()
        } catch {
            failures += 1
            print("  FAIL threw \(error)")
        }
    }

    static func finish() -> Never {
        print("\n\(checks) checks, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}

/// A throwaway directory tree, removed when the closure returns.
func withSandbox(
    _ names: [String],
    directories: Set<String> = [],
    _ body: (URL) throws -> Void
) throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pfadi-selftest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    for name in names {
        let url = root.appendingPathComponent(name)
        if directories.contains(name) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try Data("x".utf8).write(to: url)
        }
    }
    try body(root.standardizedFileURL)
}
