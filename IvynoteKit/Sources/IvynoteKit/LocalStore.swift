import CryptoKit
import Foundation
import SQLite3

/// One library's local database: each table maps an ID to a JSON document.
///
/// The sync engine keeps everything in memory and writes back what changed,
/// so the store only needs put, delete and load-all. Bodies are stored in
/// plain text (guide 8.3); the file is protected by iOS data protection.
public final class LocalStore {
    enum Table: String, CaseIterable {
        case notes, folders, tags, attachments, outbox
    }

    public struct StoreError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { "SQLite: \(message)" }
    }

    private var db: OpaquePointer?
    public let url: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Opens (creating if needed) the database at `url`; nil keeps it in memory.
    public init(url: URL?) throws {
        self.url = url
        if let url {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            #if os(iOS)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dir.path)
            #endif
        }
        let path = url?.path ?? ":memory:"
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw StoreError(message: message)
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        for t in Table.allCases {
            try exec("CREATE TABLE IF NOT EXISTS \(t.rawValue) (id TEXT PRIMARY KEY, doc BLOB NOT NULL)")
        }
        try exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
    }

    deinit { sqlite3_close(db) }

    // MARK: Documents

    func all<T: Decodable>(_ table: Table, as: T.Type = T.self) throws -> [T] {
        let stmt = try prepare("SELECT doc FROM \(table.rawValue)")
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let data = column(stmt, 0)
            // A row this build cannot read is skipped, not fatal: the next
            // snapshot or pull brings the entity back.
            if let v = try? decoder.decode(T.self, from: data) { out.append(v) }
        }
        return out
    }

    func put<T: Encodable>(_ table: Table, _ items: [(id: String, value: T)]) throws {
        guard !items.isEmpty else { return }
        let stmt = try prepare("INSERT OR REPLACE INTO \(table.rawValue) (id, doc) VALUES (?, ?)")
        defer { sqlite3_finalize(stmt) }
        for item in items {
            let data = try encoder.encode(item.value)
            sqlite3_reset(stmt)
            bind(stmt, 1, item.id)
            bind(stmt, 2, data)
            try step(stmt)
        }
    }

    func delete(_ table: Table, _ ids: some Collection<String>) throws {
        guard !ids.isEmpty else { return }
        let stmt = try prepare("DELETE FROM \(table.rawValue) WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        for id in ids {
            sqlite3_reset(stmt)
            bind(stmt, 1, id)
            try step(stmt)
        }
    }

    func clear(_ table: Table) throws {
        try exec("DELETE FROM \(table.rawValue)")
    }

    // MARK: Meta

    func meta<T: Decodable>(_ key: String, as: T.Type = T.self) -> T? {
        guard let stmt = try? prepare("SELECT value FROM meta WHERE key = ?") else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return try? decoder.decode(T.self, from: column(stmt, 0))
    }

    func setMeta<T: Encodable>(_ key: String, _ value: T) throws {
        let stmt = try prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, key)
        bind(stmt, 2, try encoder.encode(value))
        try step(stmt)
    }

    /// Runs `body` in one transaction, rolled back if it throws.
    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: Location

    /// Where an account's library lives: one database per server + user, so
    /// accounts never mix (guide 3.1).
    /// Application Support/Ivynote: every library's folder is under it.
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Ivynote", directoryHint: .isDirectory)
    }

    /// Where builds before libraries kept an account's database; only
    /// `LibraryCatalog.migrateLegacy` still needs it.
    public static func url(for account: StoredAccount, in base: URL? = nil) -> URL {
        let root = base ?? defaultRoot
        let key = "\(account.server.description)|\(account.user.id)"
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: "libraries/\(digest)/library.sqlite")
    }

    /// Deletes a library's database and everything next to it.
    public static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: SQLite plumbing

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw StoreError(message: message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError(message: String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private func step(_ stmt: OpaquePointer?) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) {
        sqlite3_bind_text(stmt, index, text, -1, Self.transient)
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ data: Data) {
        data.withUnsafeBytes { buf in
            _ = sqlite3_bind_blob(stmt, index, buf.baseAddress, Int32(buf.count), Self.transient)
        }
    }

    private func column(_ stmt: OpaquePointer?, _ index: Int32) -> Data {
        guard let p = sqlite3_column_blob(stmt, index) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, index)))
    }
}
