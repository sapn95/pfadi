import Foundation

/// Where this window has been, and where it can go back to.
///
/// The same model a browser uses, because it is the one everybody already has
/// in their fingers: going somewhere new from halfway back throws away the
/// forward half rather than branching.
public struct NavigationHistory: Equatable {
    /// Enough to cover a working day of clicking around, bounded so a long
    /// session cannot grow it without limit.
    public static let limit = 200

    public private(set) var visited: [URL] = []
    public private(set) var index: Int = -1

    public init() {}

    public var current: URL? {
        visited.indices.contains(index) ? visited[index] : nil
    }

    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index >= 0 && index < visited.count - 1 }

    /// Records arriving somewhere.
    ///
    /// Arriving where you already are is not a visit: a reload, a watcher
    /// refresh or clicking the folder you are in must not fill the history
    /// with the same entry.
    public mutating func visit(_ url: URL) {
        guard current != url else { return }

        if canGoForward {
            visited.removeSubrange((index + 1)...)
        }
        visited.append(url)

        if visited.count > Self.limit {
            visited.removeFirst(visited.count - Self.limit)
        }
        index = visited.count - 1
    }

    public mutating func back() -> URL? {
        guard canGoBack else { return nil }
        index -= 1
        return visited[index]
    }

    public mutating func forward() -> URL? {
        guard canGoForward else { return nil }
        index += 1
        return visited[index]
    }
}
