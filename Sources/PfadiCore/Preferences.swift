import Foundation

/// Somewhere to keep a handful of values between launches.
///
/// Narrow on purpose: `UserDefaults` would work directly, but then every
/// preference is a string literal at the point of use and nothing about it can
/// be tested without writing into the real user's defaults.
public protocol KeyValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: KeyValueStore {}

/// The settings that survive a quit.
///
/// Everything here is a preference in the plain sense: something chosen once
/// that should still be true next time, rather than state that belongs to a
/// particular window.
public final class Preferences {
    private let store: KeyValueStore

    public init(store: KeyValueStore = UserDefaults.standard) {
        self.store = store
    }

    /// Where the last window was looking.
    public var lastDirectory: String? {
        get { store.object(forKey: Key.lastDirectory) as? String }
        set { store.set(newValue, forKey: Key.lastDirectory) }
    }

    /// Whether dotfiles are shown. Read through `object` rather than `bool`,
    /// because a missing value and an explicit `false` are the same to
    /// `bool(forKey:)` and only one of them should be overridable by a default.
    public var showHidden: Bool {
        get { store.object(forKey: Key.showHidden) as? Bool ?? false }
        set { store.set(newValue, forKey: Key.showHidden) }
    }

    enum Key {
        static let lastDirectory = "lastDirectory"
        static let showHidden = "showHidden"
    }
}
