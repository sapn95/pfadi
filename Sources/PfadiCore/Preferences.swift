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

    /// Which column the list is sorted by, and which way.
    public var sortOrder: ListingOrder {
        get {
            let key =
                (store.object(forKey: Key.sortKey) as? String)
                .flatMap(ListingOrder.Key.init(rawValue:)) ?? .name
            let ascending = store.object(forKey: Key.sortAscending) as? Bool ?? true
            return ListingOrder(key: key, ascending: ascending)
        }
        set {
            store.set(newValue.key.rawValue, forKey: Key.sortKey)
            store.set(newValue.ascending, forKey: Key.sortAscending)
        }
    }

    /// The sidebar folders, or nil when the person has never touched them and
    /// the defaults should still apply. An empty array is a real answer: it
    /// means every one of them was removed on purpose.
    public var favourites: [String]? {
        get { store.object(forKey: Key.favourites) as? [String] }
        set { store.set(newValue, forKey: Key.favourites) }
    }

    /// Shares connected to recently, newest first, as URL strings.
    public var servers: [String] {
        get { store.object(forKey: Key.servers) as? [String] ?? [] }
        set { store.set(newValue, forKey: Key.servers) }
    }

    /// Whether a pasted `\\server\share` is understood as an address. On by
    /// default, because being told what it did is better than being refused.
    public var rewriteAddresses: Bool {
        get { store.object(forKey: Key.rewriteAddresses) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.rewriteAddresses) }
    }

    /// Folders visited recently, newest first.
    public var recents: [String] {
        get { store.object(forKey: Key.recents) as? [String] ?? [] }
        set { store.set(newValue, forKey: Key.recents) }
    }

    enum Key {
        static let favourites = "favourites"
        static let recents = "recents"
        static let servers = "servers"
        static let rewriteAddresses = "rewriteAddresses"
        static let lastDirectory = "lastDirectory"
        static let showHidden = "showHidden"
        static let sortKey = "sortKey"
        static let sortAscending = "sortAscending"
    }
}
