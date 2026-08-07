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

    /// Whether dotfiles are shown, and they are unless somebody says otherwise.
    ///
    /// This is a tool for people with opinions about .gitignore and .zshrc.
    /// Hiding those by default means the first thing everybody does is find
    /// the switch.
    ///
    /// Read through `object` rather than `bool`, because a missing value and an
    /// explicit `false` are the same to `bool(forKey:)`, and with the default
    /// now true that difference is the whole point: turning it off has to
    /// survive a relaunch.
    public var showHidden: Bool {
        get { store.object(forKey: Key.showHidden) as? Bool ?? true }
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

    /// Light, dark, or the system's choice. Dark unless somebody says
    /// otherwise, which is the point of it being a preference at all.
    public var appearance: Appearance {
        get {
            (store.object(forKey: Key.appearance) as? String)
                .flatMap(Appearance.init(rawValue:)) ?? .dark
        }
        set { store.set(newValue.rawValue, forKey: Key.appearance) }
    }

    /// Which columns are on.
    ///
    /// Which, not what order: the order on screen belongs to AppKit, kept by
    /// `autosaveTableColumns` along with the widths, so a second opinion about
    /// it here would fight the header somebody just dragged.
    ///
    /// Three by default. The rest are there for the asking, and each one costs
    /// something per entry to fill in, which is why they are a list rather than
    /// a row of switches that are all secretly on.
    ///
    /// Name is forced back in: it can be dropped from the stored list by a
    /// hand-edited preference or by a version that did not have this, and a
    /// list of sizes and dates with no names is not a list.
    public var columns: [ListingColumn] {
        get {
            guard let stored = store.object(forKey: Key.columns) as? [String] else {
                // Nothing stored under the current key. Somebody upgrading
                // from a version that had a single switch for Created had it
                // written under the old one, and silently turning their column
                // off is the kind of thing that makes an upgrade feel like a
                // loss. Read once, on the way past.
                let hadCreated = store.object(forKey: Key.legacyShowCreated) as? Bool ?? false
                return hadCreated
                    ? ListingColumn.byDefault + [.created] : ListingColumn.byDefault
            }
            var chosen = stored.compactMap(ListingColumn.init(rawValue:))
            // Emptiness is decided before name is forced back in, or an empty
            // list would become a list of one and never reach the defaults.
            // Nothing at all is not a choice somebody can make here, because
            // name cannot be switched off: it is a value from somewhere else.
            guard !chosen.isEmpty else { return ListingColumn.byDefault }
            if !chosen.contains(.name) { chosen.insert(.name, at: 0) }
            return chosen
        }
        set { store.set(newValue.map(\.rawValue), forKey: Key.columns) }
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
        static let columns = "columns"
        static let appearance = "appearance"
        /// The one switch that came before the list. Read when the list is
        /// missing, never written.
        static let legacyShowCreated = "showCreated"
    }
}
