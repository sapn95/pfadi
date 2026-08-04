import Foundation
import PfadiCore

enum HistorySuites {
    static func run() {
        let a = URL(fileURLWithPath: "/a", isDirectory: true)
        let b = URL(fileURLWithPath: "/b", isDirectory: true)
        let c = URL(fileURLWithPath: "/c", isDirectory: true)

        Harness.suite("history: nowhere to go from nowhere") {
            var history = NavigationHistory()
            Harness.expect(!history.canGoBack, "no back")
            Harness.expect(!history.canGoForward, "no forward")
            Harness.expect(history.back() == nil, "and asking gets nothing")
            Harness.expect(history.current == nil, "no current folder either")
        }

        Harness.suite("history: one visit is still nowhere to go") {
            var history = NavigationHistory()
            history.visit(a)
            Harness.expectEqual(history.current, a, "we are at a")
            Harness.expect(!history.canGoBack, "with nothing behind it")
        }

        Harness.suite("history: walking back and forward") {
            var history = NavigationHistory()
            history.visit(a)
            history.visit(b)
            history.visit(c)

            Harness.expect(history.canGoBack, "there is a way back")
            Harness.expect(!history.canGoForward, "but not forward from the end")

            Harness.expectEqual(history.back(), b, "back once")
            Harness.expectEqual(history.back(), a, "back twice")
            Harness.expect(!history.canGoBack, "and that is the beginning")
            Harness.expect(history.canGoForward, "with everything ahead")

            Harness.expectEqual(history.forward(), b, "forward again")
            Harness.expectEqual(history.forward(), c, "and again")
            Harness.expect(history.forward() == nil, "past the end there is nothing")
        }

        Harness.suite("history: going somewhere new drops the forward half") {
            var history = NavigationHistory()
            history.visit(a)
            history.visit(b)
            _ = history.back()
            history.visit(c)

            // The browser model, because it is the one already in everybody's
            // fingers: a new destination replaces the future rather than
            // branching off it.
            Harness.expect(!history.canGoForward, "b is not ahead of us any more")
            Harness.expectEqual(history.visited, [a, c], "the trail is a then c")
            Harness.expectEqual(history.back(), a, "and back still reaches a")
        }

        Harness.suite("history: arriving where you already are is not a visit") {
            var history = NavigationHistory()
            history.visit(a)
            history.visit(a)
            history.visit(a)
            // The watcher reloads constantly and a reload passes through here.
            // Without this, back would walk through the same folder repeatedly.
            Harness.expectEqual(history.visited, [a], "recorded once")
            Harness.expect(!history.canGoBack, "so there is nothing behind it")
        }

        Harness.suite("history: it does not grow forever") {
            var history = NavigationHistory()
            for index in 0...(NavigationHistory.limit + 50) {
                history.visit(URL(fileURLWithPath: "/folder-\(index)", isDirectory: true))
            }
            Harness.expectEqual(
                history.visited.count, NavigationHistory.limit, "capped at the limit")
            Harness.expectEqual(
                history.current?.lastPathComponent, "folder-\(NavigationHistory.limit + 50)",
                "and the newest is still where we are")
        }
    }
}
