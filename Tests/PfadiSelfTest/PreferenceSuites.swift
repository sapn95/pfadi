import Foundation
import PfadiCore

/// A store that lives and dies with the test, so nothing is written into the
/// real user's defaults.
final class MemoryStore: KeyValueStore {
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

extension PreferenceSuites {
    /// The settings nothing else in the tests happens to touch.
    ///
    /// Every one of these is read at launch and written when somebody changes
    /// it, and a getter with the wrong key or the wrong default fails silently:
    /// the setting appears to work and is back to its old value next launch.
    static func runRemaining() {
        Harness.suite("preferences: the created column is off until asked for") {
            let store = MemoryStore()
            let preferences = Preferences(store: store)
            Harness.expect(!preferences.showCreated, "off by default")
            preferences.showCreated = true
            Harness.expect(
                Preferences(store: store).showCreated,
                "and on again after a relaunch, which is the whole point")
            preferences.showCreated = false
            Harness.expect(!Preferences(store: store).showCreated, "and off again")
        }

        Harness.suite("preferences: rewriting pasted addresses is on until turned off") {
            let store = MemoryStore()
            Harness.expect(
                Preferences(store: store).rewriteAddresses,
                "on by default, because being told what it did beats being refused")
            Preferences(store: store).rewriteAddresses = false
            Harness.expect(
                !Preferences(store: store).rewriteAddresses, "and the choice survives")
        }

        Harness.suite("preferences: servers start empty and come back in order") {
            let store = MemoryStore()
            Harness.expectEqual(Preferences(store: store).servers, [], "nothing to begin with")
            Preferences(store: store).servers = ["smb://a/one", "nfs://b/two"]
            Harness.expectEqual(
                Preferences(store: store).servers, ["smb://a/one", "nfs://b/two"],
                "newest first, as they were written")
        }
    }
}
