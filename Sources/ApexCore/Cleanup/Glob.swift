import Darwin
import Foundation

/// Bounded shell-style path expansion that never follows directory symlinks.
public enum Glob {
    public static func expand(_ pattern: String, limit: Int = 4_000) -> [URL] {
        guard limit > 0 else { return [] }
        var expanded = pattern.expandingTilde
        if expanded == "/var" || expanded.hasPrefix("/var/") {
            expanded = "/private" + expanded
        } else if expanded == "/tmp" || expanded.hasPrefix("/tmp/") {
            expanded = "/private" + expanded
        }
        guard expanded.hasPrefix("/") else { return [] }

        let components = expanded.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        var candidates = [URL(fileURLWithPath: "/", isDirectory: true)]

        for (index, component) in components.enumerated() {
            let isFinal = index == components.count - 1
            let hasMagic = component.contains { "*?[".contains($0) }
            var next: [URL] = []

            for parent in candidates.sorted(by: { $0.path < $1.path }) {
                if hasMagic {
                    guard
                        let children = try? FileManager.default.contentsOfDirectory(
                            at: parent,
                            includingPropertiesForKeys: [
                                .isDirectoryKey, .isSymbolicLinkKey,
                            ],
                            options: []
                        )
                    else { continue }

                    let sorted = children.sorted { $0.lastPathComponent < $1.lastPathComponent }
                    for child in sorted {
                        let name = child.lastPathComponent
                        if name.hasPrefix("."), !component.hasPrefix(".") { continue }
                        guard fnmatch(component, name, 0) == 0 else { continue }
                        guard isFinal || mayDescend(into: child) else { continue }
                        next.append(child)
                        if next.count >= limit { break }
                    }
                } else {
                    let child = parent.appendingPathComponent(component)
                    guard FileManager.default.fileExists(atPath: child.path) else { continue }
                    guard isFinal || mayDescend(into: child) else { continue }
                    next.append(child)
                }
                if next.count >= limit { break }
            }

            candidates = next
            if candidates.isEmpty { break }
            if candidates.count >= limit {
                Log.engine.notice(
                    "Glob expansion reached its path limit: \(pattern, privacy: .public)"
                )
            }
        }

        return Array(candidates.prefix(limit))
    }

    private static func mayDescend(into url: URL) -> Bool {
        guard
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
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
