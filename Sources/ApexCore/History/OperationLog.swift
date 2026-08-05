import Foundation

/// Durable, append-only accountability for every completed operation.
public final class OperationLog: @unchecked Sendable {
    public static let didChange = Notification.Name("ApexCleanOperationLogDidChange")
    public struct Entry: Codable, Identifiable, Hashable, Sendable {
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

    public struct Session: Codable, Identifiable, Hashable, Sendable {
        public var id = UUID()
        public var title: String
        public var date: Date
        public var bytes: Int64
        public var itemCount: Int
        public var recoverableCount: Int
    }

    private struct Store: Codable {
        var version = 1
        var entries: [Entry] = []
        var sessions: [Session] = []
    }

    private enum StoreError: Error {
        case tooLarge
        case corrupt
    }

    private let queue = DispatchQueue(label: "fit.apexclean.history")
    private let directory: URL
    private var cachedStore: Store?
    private static let maximumStoreBytes: Int64 = 64 * 1024 * 1024

    public convenience init() {
        self.init(
            directory: PathGuard.home
                .appendingPathComponent("Library/Application Support/ApexClean", isDirectory: true)
        )
    }

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        for name in ["operations.json", "sessions.json", "history-v1.json"] {
            let path = directory.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: path
                )
            }
        }
    }

    private var storeURL: URL { directory.appendingPathComponent("history-v1.json") }
    private var legacyEntriesURL: URL { directory.appendingPathComponent("operations.json") }
    private var legacySessionsURL: URL { directory.appendingPathComponent("sessions.json") }

    /// Atomically appends one operation's entries and summary. Entries from
    /// another feature can never be consumed by this session.
    @discardableResult
    public func commitSession(title: String, entries: [Entry]) -> Session? {
        guard !entries.isEmpty else { return nil }
        return queue.sync {
            do {
                var store = try loadStore()
                let session = Session(
                    title: title,
                    date: Date(),
                    bytes: saturatingSum(entries.map(\.bytes)),
                    itemCount: entries.count,
                    recoverableCount: entries.filter(\.recoverable).count
                )
                store.entries.append(contentsOf: entries)
                store.sessions.append(session)
                try persist(store)
                cachedStore = store
                NotificationCenter.default.post(name: Self.didChange, object: self)
                return session
            } catch {
                Log.safety.error(
                    "Could not commit operation history: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }
    }

    public func recentSessions(limit: Int = 25) -> [Session] {
        queue.sync {
            guard let store = try? loadStore() else { return [] }
            return Array(store.sessions.suffix(max(0, limit)).reversed())
        }
    }

    public func recentEntries(limit: Int = 200) -> [Entry] {
        queue.sync {
            guard let store = try? loadStore() else { return [] }
            return Array(store.entries.suffix(max(0, limit)).reversed())
        }
    }

    public func totalProcessed() -> Int64 {
        queue.sync {
            guard let store = try? loadStore() else { return 0 }
            return saturatingSum(store.sessions.map(\.bytes))
        }
    }

    private func loadStore() throws -> Store {
        if let cachedStore { return cachedStore }
        let loaded: Store
        if FileManager.default.fileExists(atPath: storeURL.path) {
            loaded = try decode(Store.self, from: storeURL)
        } else {
            loaded = Store(
                entries: try decodeLegacy([Entry].self, from: legacyEntriesURL),
                sessions: try decodeLegacy([Session].self, from: legacySessionsURL)
            )
        }
        cachedStore = loaded
        return loaded
    }

    private func decodeLegacy<Element: Decodable>(
        _ type: [Element].Type, from url: URL
    ) throws
        -> [Element]
    {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try decode(type, from: url)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber,
            size.int64Value > Self.maximumStoreBytes
        {
            throw StoreError.tooLarge
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(type, from: data) else {
            throw StoreError.corrupt
        }
        return value
    }

    private func persist(_ store: Store) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(store)
        try data.write(to: storeURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storeURL.path
        )
    }

    private func saturatingSum(_ values: [Int64]) -> Int64 {
        values.reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            return overflow ? Int64.max : max(0, sum)
        }
    }
}
