import Darwin
import Foundation

/// Durable accountability for every completed operation.
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
        var totalProcessed: Int64 = 0
        var totalSessions: Int = 0

        private enum CodingKeys: String, CodingKey {
            case version, entries, sessions, totalProcessed, totalSessions
        }

        init(
            entries: [Entry] = [],
            sessions: [Session] = [],
            totalProcessed: Int64 = 0,
            totalSessions: Int = 0
        ) {
            self.entries = entries
            self.sessions = sessions
            self.totalProcessed = totalProcessed
            self.totalSessions = totalSessions
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            entries = try container.decodeIfPresent([Entry].self, forKey: .entries) ?? []
            sessions = try container.decodeIfPresent([Session].self, forKey: .sessions) ?? []
            totalProcessed =
                try container.decodeIfPresent(Int64.self, forKey: .totalProcessed)
                ?? OperationLog.saturatingSum(sessions.map(\.bytes))
            totalSessions =
                try container.decodeIfPresent(Int.self, forKey: .totalSessions)
                ?? sessions.count
        }
    }

    private enum StoreError: Error {
        case tooLarge
        case corrupt
        case lockUnavailable
    }

    private let queue = DispatchQueue(label: "fit.apexclean.history")
    private let directory: URL
    private static let maximumStoreBytes: Int64 = 64 * 1024 * 1024
    private static let retainedEntries = 5_000
    private static let retainedSessions = 200

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
        for name in ["operations.json", "sessions.json", "history-v1.json", "history.lock"] {
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
    private var lockURL: URL { directory.appendingPathComponent("history.lock") }
    private var legacyEntriesURL: URL { directory.appendingPathComponent("operations.json") }
    private var legacySessionsURL: URL { directory.appendingPathComponent("sessions.json") }

    @discardableResult
    public func commitSession(title: String, entries: [Entry]) -> Session? {
        guard !entries.isEmpty else { return nil }
        return queue.sync {
            do {
                let session = try withStoreLock(exclusive: true) {
                    var store = try loadStore()
                    let session = Session(
                        title: title,
                        date: Date(),
                        bytes: Self.saturatingSum(entries.map(\.bytes)),
                        itemCount: entries.count,
                        recoverableCount: entries.filter(\.recoverable).count
                    )
                    store.totalProcessed = Self.saturatingAdd(
                        store.totalProcessed,
                        session.bytes
                    )
                    store.totalSessions = min(Int.max, store.totalSessions + 1)
                    store.entries.append(contentsOf: entries)
                    store.sessions.append(session)
                    if store.entries.count > Self.retainedEntries {
                        store.entries.removeFirst(store.entries.count - Self.retainedEntries)
                    }
                    if store.sessions.count > Self.retainedSessions {
                        store.sessions.removeFirst(store.sessions.count - Self.retainedSessions)
                    }
                    try persist(store)
                    return session
                }
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
            (try? withStoreLock(exclusive: false) {
                Array(try loadStore().sessions.suffix(max(0, limit)).reversed())
            }) ?? []
        }
    }

    public func recentEntries(limit: Int = 200) -> [Entry] {
        queue.sync {
            (try? withStoreLock(exclusive: false) {
                Array(try loadStore().entries.suffix(max(0, limit)).reversed())
            }) ?? []
        }
    }

    public func totalProcessed() -> Int64 {
        queue.sync {
            (try? withStoreLock(exclusive: false) {
                try loadStore().totalProcessed
            }) ?? 0
        }
    }

    public func totalSessionCount() -> Int {
        queue.sync {
            (try? withStoreLock(exclusive: false) {
                try loadStore().totalSessions
            }) ?? 0
        }
    }

    private func loadStore() throws -> Store {
        if FileManager.default.fileExists(atPath: storeURL.path) {
            return try decode(Store.self, from: storeURL)
        }
        let entries = try decodeLegacy([Entry].self, from: legacyEntriesURL)
        let sessions = try decodeLegacy([Session].self, from: legacySessionsURL)
        return Store(
            entries: Array(entries.suffix(Self.retainedEntries)),
            sessions: Array(sessions.suffix(Self.retainedSessions)),
            totalProcessed: Self.saturatingSum(sessions.map(\.bytes)),
            totalSessions: sessions.count
        )
    }

    private func decodeLegacy<Element: Decodable>(
        _ type: [Element].Type, from url: URL
    ) throws -> [Element] {
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
        guard data.count <= Self.maximumStoreBytes else { throw StoreError.tooLarge }
        try data.write(to: storeURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storeURL.path
        )
    }

    private func withStoreLock<Value>(
        exclusive: Bool,
        _ body: () throws -> Value
    ) throws -> Value {
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw StoreError.lockUnavailable }
        defer { close(descriptor) }
        guard flock(descriptor, exclusive ? LOCK_EX : LOCK_SH) == 0 else {
            throw StoreError.lockUnavailable
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : max(0, sum)
    }

    private static func saturatingSum(_ values: [Int64]) -> Int64 {
        values.reduce(0, saturatingAdd)
    }
}
