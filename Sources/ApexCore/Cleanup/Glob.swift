import Foundation

/// Thin wrapper over POSIX `glob(3)`.
///
/// Shell-style patterns are the natural way to express "every profile directory
/// under Chrome", and re-implementing that matching in Swift would be a source
/// of subtle over-matching bugs in code whose whole job is to delete things.
public enum Glob {
    public static func expand(_ pattern: String, limit: Int = 4_000) -> [URL] {
        var results = glob_t()
        defer { globfree(&results) }

        let flags = GLOB_TILDE | GLOB_NOSORT | GLOB_MARK
        guard glob(pattern, flags, nil, &results) == 0 else { return [] }

        let count = min(Int(results.gl_pathc), limit)
        guard count > 0, let paths = results.gl_pathv else { return [] }

        var urls: [URL] = []
        urls.reserveCapacity(count)
        for index in 0 ..< count {
            guard let raw = paths[index] else { continue }
            var path = String(cString: raw)
            // GLOB_MARK appends "/" to directories; URL handles that, but the
            // trailing slash makes string comparisons in PathGuard noisier.
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            urls.append(URL(fileURLWithPath: path))
        }
        return urls
    }

    /// Expands `~` without touching the filesystem, for patterns we want to
    /// display rather than resolve.
    public static func display(_ pattern: String) -> String {
        pattern.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

public extension String {
    /// Resolves a leading `~` to the home directory. Used to reason about where
    /// a glob *would* look before actually looking there.
    var expandingTilde: String {
        guard hasPrefix("~") else { return self }
        return NSHomeDirectory() + dropFirst()
    }
}
