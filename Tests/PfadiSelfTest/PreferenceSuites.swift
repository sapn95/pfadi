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
        Harness.suite("preferences: three columns until somebody asks for more") {
            let store = MemoryStore()
            Harness.expectEqual(
                Preferences(store: store).columns, ListingColumn.byDefault,
                "name, size and modified to begin with")

            Preferences(store: store).columns = [.name, .size, .permissions, .owner]
            Harness.expectEqual(
                Preferences(store: store).columns, [.name, .size, .permissions, .owner],
                "and the choice survives a relaunch, which is the whole point")
        }

        Harness.suite("preferences: name is put back however it was lost") {
            // A hand-edited preference, or one written by a version that did
            // not have this. A list of sizes and dates with nothing saying
            // which file they belong to is not a list.
            let store = MemoryStore()
            store.set(["size", "modified"], forKey: "columns")
            Harness.expectEqual(
                Preferences(store: store).columns, [.name, .size, .modified],
                "name goes back at the front")

            let empty = MemoryStore()
            empty.set([String](), forKey: "columns")
            Harness.expectEqual(
                Preferences(store: empty).columns, ListingColumn.byDefault,
                "and nothing at all falls back to the defaults")
        }

        Harness.suite("preferences: a column that no longer exists is dropped") {
            let store = MemoryStore()
            store.set(["name", "size", "somethingRemoved"], forKey: "columns")
            Harness.expectEqual(
                Preferences(store: store).columns, [.name, .size],
                "rather than crashing on a name from a future version")
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

extension PreferenceSuites {
    /// What happens to somebody upgrading from the version before this one.
    static func runUpgrade() {
        Harness.suite("preferences: an upgrade keeps the Created column") {
            // 0.26.0 had one switch rather than a list. Reading the new key,
            // finding nothing and quietly falling back to the defaults would
            // turn their column off for them, which makes an upgrade feel like
            // a loss.
            let store = MemoryStore()
            store.set(true, forKey: "showCreated")
            Harness.expectEqual(
                Preferences(store: store).columns,
                ListingColumn.byDefault + [.created],
                "the old switch is honoured once, on the way past")
        }

        Harness.suite("preferences: an upgrade that never wanted it gets the defaults") {
            let off = MemoryStore()
            off.set(false, forKey: "showCreated")
            Harness.expectEqual(
                Preferences(store: off).columns, ListingColumn.byDefault,
                "an explicit no stays no")

            let never = MemoryStore()
            Harness.expectEqual(
                Preferences(store: never).columns, ListingColumn.byDefault,
                "and somebody who never had either key gets the three")
        }

        Harness.suite("preferences: the new list wins over the old switch") {
            // Once the list exists, the old key is history. Reading both would
            // put a column back that was switched off after the upgrade.
            let store = MemoryStore()
            store.set(true, forKey: "showCreated")
            store.set(["name", "size"], forKey: "columns")
            Harness.expectEqual(
                Preferences(store: store).columns, [.name, .size],
                "the list is the answer, and the old switch is not consulted")
        }
    }
}

extension PreferenceSuites {
    /// The appearance, which is the one preference with an opinionated default.
    static func runAppearance() {
        Harness.suite("appearance: dark unless somebody says otherwise") {
            let store = MemoryStore()
            Harness.expectEqual(
                Preferences(store: store).appearance, .dark,
                "a tool for people who spend the day in a terminal")

            Preferences(store: store).appearance = .light
            Harness.expectEqual(
                Preferences(store: store).appearance, .light,
                "and the choice survives a relaunch")
        }

        Harness.suite("appearance: Match System is not the same as light") {
            // nil hands the decision back to macOS, which is the only answer
            // that follows a schedule. Treating it as light would pin somebody
            // to light at midnight.
            Harness.expect(
                Appearance.system.appearanceName == nil,
                "it overrides nothing")
            Harness.expect(
                Appearance.light.appearanceName != nil,
                "while light is an override like any other")
        }

        Harness.suite("appearance: the names are the ones AppKit knows") {
            // Spelled out because a typo is silent: NSAppearance(named:)
            // returns nil for a name it does not know, which reads as
            // "match the system" and looks like the setting doing nothing.
            Harness.expectEqual(
                Appearance.dark.appearanceName, "NSAppearanceNameDarkAqua", "dark")
            Harness.expectEqual(
                Appearance.light.appearanceName, "NSAppearanceNameAqua", "light")
        }

        Harness.suite("appearance: a value from somewhere else falls back to dark") {
            let store = MemoryStore()
            store.set("solarized", forKey: "appearance")
            Harness.expectEqual(
                Preferences(store: store).appearance, .dark,
                "rather than crashing on a name from a future version")
        }
    }
}

extension PreferenceSuites {
    /// One settings store, shared by every part of pfadi.
    static func runSharedStore() {
        Harness.suite("preferences: every process reads the same file") {
            // UserDefaults.standard is a different file in each of them: the
            // app bundle writes io.github.sapn95.pfadi.plist, pfadi-default
            // writes pfadi-default.plist, an unbundled build writes
            // pfadi.plist. `pfadi-default credentials` wrote to one the window
            // never read, and the setting silently did nothing.
            Harness.expectEqual(
                Preferences.suiteName, "io.github.sapn95.pfadi.settings",
                "a named suite every one of them can open")
            Harness.expect(
                Preferences.suiteName != "io.github.sapn95.pfadi",
                "and not the bundle identifier, which Apple says not to pass to suiteName")
        }

        Harness.suite("preferences: the shared store is what a Preferences() uses") {
            // The default argument, because a Preferences() built with no
            // store is what every call site in the application uses.
            let key = "selftest-\(UUID().uuidString)"
            Preferences.shared.set("written", forKey: key)
            defer { Preferences.shared.removeObject(forKey: key) }

            Harness.expectEqual(
                UserDefaults(suiteName: Preferences.suiteName)?.string(forKey: key), "written",
                "so a second process opening the suite by name finds it")
        }
    }
}
