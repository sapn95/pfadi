import Foundation

/// Light, dark, or whatever the system is doing.
///
/// Dark is the default rather than following the system, which is the unusual
/// choice and a deliberate one: this is a tool for people who spend the day in
/// a terminal, and a file list is the one window that would otherwise be a
/// sheet of white in the middle of that. Following the system is still there
/// for anybody who wants it.
public enum Appearance: String, CaseIterable, Sendable {
    case dark
    case light
    case system

    public var title: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .system: return "Match System"
        }
    }

    /// The name AppKit knows it by, or nothing for "do not override".
    ///
    /// A string rather than an `NSAppearance.Name`, so this stays in the half
    /// of the project that has no AppKit in it and can be tested.
    public var appearanceName: String? {
        switch self {
        case .dark: return "NSAppearanceNameDarkAqua"
        case .light: return "NSAppearanceNameAqua"
        // nil is not "light": it hands the decision back to the system, which
        // is a third answer and the only one that follows a schedule.
        case .system: return nil
        }
    }
}
