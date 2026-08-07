import Foundation

/// pfadi's own URL scheme, for asking a copy that is already running to do
/// something a file URL cannot express.
///
/// There is exactly one such thing so far: "select this, in the folder holding
/// it". A file URL handed to a running application says only "here is a file",
/// and the application has to guess whether that means open it or point at it.
/// Guessing from whether it happens to be a directory gets `pfadi -R somefolder`
/// wrong every time, so the intent travels with the request instead.
public enum PfadiURL {
    public static let scheme = "pfadi"

    /// `pfadi://reveal?path=/some/where`.
    public static func reveal(_ url: URL) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "reveal"
        // A path goes in a query item so that percent-encoding is somebody
        // else's problem: a file really can be called `a?b#c`, and building
        // this string by hand is how that turns into a truncated path.
        components.queryItems = [URLQueryItem(name: "path", value: url.path)]
        // Cannot fail: the scheme and host are literals and the path is
        // escaped by URLComponents. The fallback is there so this returns a
        // URL rather than an optional nobody can act on.
        return components.url ?? URL(fileURLWithPath: url.path)
    }

    /// Reads one back, or nothing when it is not ours.
    ///
    /// Returns a target rather than a URL so the caller cannot forget which of
    /// the two meanings it had.
    public static func target(of url: URL) -> PathCompletion.Target? {
        guard url.scheme == scheme else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.host == "reveal",
            let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
            !path.isEmpty
        else { return nil }
        return .file(URL(fileURLWithPath: path).standardizedFileURL)
    }
}
