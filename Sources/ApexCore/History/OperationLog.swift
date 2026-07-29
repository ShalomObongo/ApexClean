import Foundation

/// Append-only record of everything ApexClean removed, so a user can always
/// answer "what did this app touch, and can I get it back?".
public final class OperationLog {
    public struct Entry: Codable, Identifiable, Hashable {
        public var id = UUID()
        public var path: String
        public var bytes: Int64
        public var recoverable: Bool
        public var date: Date

        public init(path: String, bytes: Int64, recoverable: Bool, date: Date) {
            self.path = path
            self.bytes = bytes
            self.recoverable = recoverable
            self.date = date
        }
    }

    public struct Session: Codable, Identifiable, Hashable {
        public var id = UUID()
        public var title: String
        public var date: Date
        public var bytes: Int64
        public var itemCount: Int
        public var recoverableCount: Int
    }

    private let queue = DispatchQueue(label: "fit.apexclean.history")
    private let directory: URL
    private var pending: [Entry] = []

    public init() {
        directory = PathGuard.home
            .appendingPathComponent("Library/Application Support/ApexClean", isDirectory: true)
        // 0700. The history is a list of every path this app has removed —
        // project directories, filenames, the contents of the user's Trash —
        // and it was being written 0644 inside a 0755 directory. Containment
        // rested entirely on `~/Library/Application Support` happening to be
        // private, which is not something to depend on across a restored home
        // folder, a shared machine, or any other app holding Full Disk Access.
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private var entriesURL: URL { directory.appendingPathComponent("operations.json") }
    private var sessionsURL: URL { directory.appendingPathComponent("sessions.json") }

    public func record(_ entry: Entry) {
        queue.sync { pending.append(entry) }
    }

    /// Seals the pending entries into a named session and persists them.
    @discardableResult
    public func commitSession(title: String) -> Session? {
        queue.sync {
            guard !pending.isEmpty else { return nil }
            let entries = pending
            pending.removeAll()

            let session = Session(
                title: title,
                date: Date(),
                bytes: entries.reduce(0) { $0 + $1.bytes },
                itemCount: entries.count,
                recoverableCount: entries.filter(\.recoverable).count
            )

            var allEntries = loadEntries()
            allEntries.append(contentsOf: entries)
            // Keep the log bounded; the tail is what people actually consult.
            if allEntries.count > 5_000 { allEntries.removeFirst(allEntries.count - 5_000) }
            persist(allEntries, to: entriesURL)

            var sessions = loadSessions()
            sessions.append(session)
            if sessions.count > 200 { sessions.removeFirst(sessions.count - 200) }
            persist(sessions, to: sessionsURL)

            return session
        }
    }

    public func recentSessions(limit: Int = 25) -> [Session] {
        queue.sync { Array(loadSessions().suffix(limit).reversed()) }
    }

    public func recentEntries(limit: Int = 200) -> [Entry] {
        queue.sync { Array(loadEntries().suffix(limit).reversed()) }
    }

    public func totalReclaimed() -> Int64 {
        queue.sync { loadSessions().reduce(0) { $0 + $1.bytes } }
    }

    // MARK: - Persistence

    private func loadEntries() -> [Entry] { load(entriesURL) }
    private func loadSessions() -> [Session] { load(sessionsURL) }

    private func load<T: Decodable>(_ url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([T].self, from: data)) ?? []
    }

    private func persist<T: Encodable>(_ value: [T], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
        // `.atomic` replaces the file, so the mode has to be reapplied after
        // every write rather than set once at creation.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
