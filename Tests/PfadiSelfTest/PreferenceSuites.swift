import Foundation
import PfadiCore

/// A store that lives and dies with the test, so nothing is written into the
/// real user's defaults.
private final class MemoryStore: KeyValueStore {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }

    func set(_ value: Any?, forKey key: String) {
        if let value {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
    }
}

enum PreferenceSuites {
    static func run() {
        Harness.suite("preferences: nothing set yet") {
            let preferences = Preferences(store: MemoryStore())
            Harness.expect(preferences.lastDirectory == nil, "no folder remembered")
            Harness.expect(preferences.showHidden, "dotfiles are shown by default")
        }

        Harness.suite("preferences: a choice survives") {
            let store = MemoryStore()
            let first = Preferences(store: store)
            first.showHidden = true
            first.lastDirectory = "/Users/someone/git"

            // A second instance over the same store is what the next launch
            // looks like.
            let next = Preferences(store: store)
            Harness.expect(next.showHidden, "showing dotfiles is still true")
            Harness.expectEqual(
                next.lastDirectory, "/Users/someone/git", "and the folder is still there")
        }

        Harness.suite("preferences: turning a choice back off sticks too") {
            let store = MemoryStore()
            let preferences = Preferences(store: store)
            preferences.showHidden = false

            // The bug this guards, and it is live now that the default is true:
            // bool(forKey:) cannot tell an explicit false from a value that was
            // never written, so turning dotfiles off would be undone on every
            // single launch.
            Harness.expect(
                store.object(forKey: "showHidden") as? Bool == false,
                "false is written down, not just left absent")
            Harness.expect(!Preferences(store: store).showHidden, "and reads back as false")
        }
    }
}
