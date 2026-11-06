import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "app.ivynote", category: "libraries")

/// One library on this device, as the desktop client has them
/// (`client/packages/core/src/library.ts`).
///
/// A library is one independent collection of notes: `local` lives only on
/// this device (no account, no sync), `server` syncs with one Ivynote server.
/// Each has its own database and its own sign-in, so switching never mixes
/// data. The kind is fixed at creation. A local library can still move to
/// the cloud, but only into a newly registered, empty account: its content
/// is copied into a new synced library (`LibraryMigrator`), so two histories
/// of the same notes are never merged. The local one stays, marked with
/// where it went, until the person removes it.
public struct LibraryRef: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case local, server }

    public let id: String
    public let kind: Kind
    public var name: String
    /// The sync target, for `server` libraries.
    public let server: ServerAddress?
    /// The account last signed in: its username for display, its ID to tell
    /// when a different account signs in (whose notes must not mix in).
    public var account: String?
    public var userID: String?
    public let createdAt: Millis
    public var openedAt: Millis
    /// A local library copied to the cloud: the synced library that holds it now.
    public var migratedTo: String?

    public var isLocal: Bool { kind == .local }
    /// A local library that can still turn on sync.
    public var canTurnOnSync: Bool { kind == .local && migratedTo == nil }
}

/// The libraries on this device and which one is open. The list lives in
/// user defaults; each server library's token in its own Keychain item.
@MainActor
@Observable
public final class LibraryCatalog {
    public private(set) var libraries: [LibraryRef] = []
    public private(set) var activeID: String?
    /// A local library whose "Turn on sync" was chosen from inside it: the
    /// library list opens the sign-up for it once the library has closed.
    public var pendingSync: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let makeCredentials: (String) -> CredentialStore
    @ObservationIgnored private let now: () -> Millis

    static let listKey = "ivy.libraries"
    static let activeKey = "ivy.library"

    public init(defaults: UserDefaults = .standard,
                root: URL? = nil,
                credentials: @escaping (String) -> CredentialStore = { KeychainCredentialStore(account: "library.\($0)") },
                now: @escaping () -> Millis = { Millis(Date().timeIntervalSince1970 * 1000) }) {
        self.defaults = defaults
        self.root = root ?? LocalStore.defaultRoot
        self.makeCredentials = credentials
        self.now = now
        if let data = defaults.data(forKey: Self.listKey),
           let list = try? JSONDecoder().decode([LibraryRef].self, from: data) {
            libraries = list
        }
        activeID = defaults.string(forKey: Self.activeKey).flatMap { id in libraries.contains { $0.id == id } ? id : nil }
    }

    public var active: LibraryRef? { activeID.flatMap(library) }

    public func library(_ id: String) -> LibraryRef? { libraries.first { $0.id == id } }

    /// The sign-in of a server library.
    public func credentials(for id: String) -> CredentialStore { makeCredentials(id) }

    /// Where a library's database lives.
    public func storeURL(for id: String) -> URL {
        root.appending(path: "libraries/\(id)/library.sqlite")
    }

    // MARK: Changes

    @discardableResult
    public func createLocal(name: String) -> LibraryRef {
        add(LibraryRef(id: Self.newID(), kind: .local, name: clean(name, or: "我的笔记"), server: nil,
                       account: nil, userID: nil, createdAt: now(), openedAt: now()))
    }

    @discardableResult
    public func createServer(_ server: ServerAddress, name: String) -> LibraryRef {
        add(LibraryRef(id: Self.newID(), kind: .server, name: clean(name, or: server.host), server: server,
                       account: nil, userID: nil, createdAt: now(), openedAt: now()))
    }

    /// Adds a synced library for an account that has already signed in, so
    /// no library exists for a server nobody could sign in to. Opens it.
    @discardableResult
    public func createSignedIn(_ server: ServerAddress, name: String, token: String, user: User) throws -> LibraryRef {
        let ref = LibraryRef(id: Self.newID(), kind: .server, name: clean(name, or: server.host), server: server,
                             account: user.username, userID: user.id, createdAt: now(), openedAt: now())
        try credentials(for: ref.id).save(StoredAccount(server: server, token: token, user: user))
        return add(ref)
    }

    /// Records that a local library was copied into the synced library `target`.
    public func markMigrated(_ id: String, to target: String) {
        update(id) { if $0.isLocal { $0.migratedTo = target } }
    }

    /// Leaves an open local library to turn on sync for it from the list.
    public func turnOnSync(_ id: String) {
        guard library(id)?.canTurnOnSync == true else { return }
        pendingSync = id
        open(nil)
    }

    /// Opens a library; nil goes back to the list.
    public func open(_ id: String?) {
        guard let id, library(id) != nil else {
            activeID = nil
            defaults.removeObject(forKey: Self.activeKey)
            return
        }
        activeID = id
        defaults.set(id, forKey: Self.activeKey)
        update(id) { $0.openedAt = now() }
    }

    public func rename(_ id: String, to name: String) {
        update(id) { $0.name = clean(name, or: $0.name) }
    }

    /// Records who signed in to a server library.
    public func signedIn(_ id: String, user: User) {
        update(id) {
            $0.account = user.username
            $0.userID = user.id
        }
    }

    /// Forgets a library and deletes everything of it on this device:
    /// database, sign-in and view state. Server data is untouched.
    public func remove(_ id: String) {
        LocalStore.remove(at: storeURL(for: id))
        try? credentials(for: id).clear()
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("ivy.lib.\(id).") {
            defaults.removeObject(forKey: key)
        }
        libraries.removeAll { $0.id == id }
        save()
        if activeID == id { open(nil) }
    }

    // MARK: Before libraries

    /// Builds 0.1 had one signed-in account and its database. The first start
    /// after the update turns it into a server library, moving the database
    /// so nothing has to download again and unsynced edits are kept.
    ///
    /// Without the sign-in (signed out, or the Keychain item is gone) the
    /// database is still found through the shelf state those builds kept per
    /// `server|userID`: the library then asks to sign in, and the same
    /// account picks up its notes where they were.
    public func migrateLegacy(from legacy: CredentialStore = KeychainCredentialStore()) {
        guard defaults.data(forKey: Self.listKey) == nil else { return }
        let found: StoredAccount?
        do { found = try legacy.load() } catch {
            // The Keychain may be locked right now: try again next start.
            log.error("legacy sign-in unreadable: \(String(describing: error), privacy: .public)")
            return
        }
        defer { save() }
        if let account = found {
            log.info("moving the signed-in account into a library")
            let ref = adopt(server: account.server, user: account.user)
            try? credentials(for: ref.id).save(account)
            try? legacy.clear()
            open(ref.id)
            return
        }
        let prefix = "ivy.shelf.expanded."
        var first: String?
        for key in defaults.dictionaryRepresentation().keys.sorted() where key.hasPrefix(prefix) {
            let parts = key.dropFirst(prefix.count).split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let server = try? ServerAddress(parsing: parts[0]) else { continue }
            let user = User(id: parts[1], username: "")
            let probe = StoredAccount(server: server, token: "", user: user)
            guard FileManager.default.fileExists(atPath: LocalStore.url(for: probe, in: root).path) else { continue }
            log.info("moving a signed-out account's notes into a library")
            let ref = adopt(server: server, user: user)
            defaults.set(defaults.object(forKey: key), forKey: "ivy.lib.\(ref.id).expanded")
            defaults.removeObject(forKey: key)
            first = first ?? ref.id
        }
        if let first { open(first) }
    }

    /// A server library over a database from before libraries.
    private func adopt(server: ServerAddress, user: User) -> LibraryRef {
        var ref = createServer(server, name: server.host)
        ref.account = user.username.isEmpty ? nil : user.username
        ref.userID = user.id
        update(ref.id) { $0 = ref }
        let old = LocalStore.url(for: StoredAccount(server: server, token: "", user: user), in: root).deletingLastPathComponent()
        let new = storeURL(for: ref.id).deletingLastPathComponent()
        let fm = FileManager.default
        if fm.fileExists(atPath: old.path) {
            try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: old, to: new)
        }
        return ref
    }

    // MARK: Plumbing

    private func add(_ ref: LibraryRef) -> LibraryRef {
        libraries.append(ref)
        save()
        open(ref.id)
        return ref
    }

    private func update(_ id: String, _ change: (inout LibraryRef) -> Void) {
        guard let i = libraries.firstIndex(where: { $0.id == id }) else { return }
        change(&libraries[i])
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(libraries) { defaults.set(data, forKey: Self.listKey) }
    }

    private func clean(_ name: String, or fallback: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? fallback : String(n.prefix(60))
    }

    static func newID() -> String { String(newEntityID().prefix(12)) }
}
