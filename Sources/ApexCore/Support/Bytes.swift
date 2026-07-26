import Foundation

/// Human-readable byte formatting tuned for a cleanup UI: compact, stable width,
/// and never showing more precision than the number deserves.
public enum Bytes {
    public static func format(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        if value < 1000 { return "\(Int(value)) B" }

        let units = ["KB", "MB", "GB", "TB", "PB"]
        var scaled = value / 1024
        var index = 0
        while scaled >= 1000, index < units.count - 1 {
            scaled /= 1024
            index += 1
        }

        let unit = units[index]
        if scaled >= 100 { return String(format: "%.0f %@", scaled, unit) }
        if scaled >= 10 { return String(format: "%.1f %@", scaled, unit) }
        return String(format: "%.2f %@", scaled, unit)
    }

    /// Splits the formatted value so a UI can typeset the number and the unit
    /// with different fonts without re-parsing a joined string.
    public static func parts(_ bytes: Int64) -> (value: String, unit: String) {
        let formatted = format(bytes)
        let pieces = formatted.split(separator: " ")
        guard pieces.count == 2 else { return (formatted, "") }
        return (String(pieces[0]), String(pieces[1]))
    }
}

public enum Count {
    public static func items(_ n: Int) -> String {
        n == 1 ? "1 item" : "\(n) items"
    }

    public static func files(_ n: Int) -> String {
        n == 1 ? "1 file" : "\(n) files"
    }

    public static func groups(_ n: Int) -> String {
        n == 1 ? "1 group" : "\(n) groups"
    }
}

public enum RelativeTime {
    public static func short(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        let days = Int(seconds / 86_400)
        if days < 30 { return "\(days)d ago" }
        if days < 365 { return "\(days / 30)mo ago" }
        return "\(days / 365)y ago"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
