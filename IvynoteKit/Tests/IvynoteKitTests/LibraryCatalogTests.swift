import Foundation
import Testing
@testable import IvynoteKit

/// Per-library credentials in memory, shared across catalog instances.
final class CredentialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stores: [String: InMemoryCredentialStore] = [:]
    func store(_ id: String) -> CredentialStore {
        lock.withLock {
            if let s = stores[id] { return s }
            let s = InMemoryCredentialStore()
            stores[id] = s
            return s
        }
    }
}

@MainActor
@Suite struct LibraryCatalogTests {
    let server = try! ServerAddress(parsing: "https://notes.example.com")
    let defaults = UserDefaults(suiteName: "ivy.tests.\(UUID().uuidString)")!
    let root = FileManager.default.temporaryDirectory.appending(path: "ivy-cat-\(UUID())")
    let box = CredentialBox()

    func catalog() -> LibraryCatalog {
        LibraryCatalog(defaults: defaults, root: root, credentials: box.store)
    }

    @Test func createdLibrariesPersistAndOpen() {
        let c = catalog()
        #expect(c.libraries.isEmpty && c.active == nil)
        let local = c.createLocal(name: "  ")
        #expect(local.name == "我的笔记" && local.isLocal && c.activeID == local.id)
        let synced = c.createServer(server, name: "")
        #expect(synced.name == "notes.example.com" && synced.server == server && c.activeID == synced.id)

        let again = catalog()
        #expect(again.libraries.map(\.id) == [local.id, synced.id])
        #expect(again.activeID == synced.id)
        #expect(again.storeURL(for: local.id) != again.storeURL(for: synced.id))
    }

    @Test func openNilGoesBackToTheList() {
        let c = catalog()
        c.createLocal(name: "A")
        c.open(nil)
        #expect(c.active == nil)
        #expect(catalog().active == nil)
        c.open("missing")
        #expect(c.active == nil)
    }

    @Test func removeDeletesTheDatabaseAndSignIn() throws {
        let c = catalog()
        let ref = c.createServer(server, name: "Work")
        let url = c.storeURL(for: ref.id)
        _ = try LocalStore(url: url)
        try c.credentials(for: ref.id).save(StoredAccount(server: server, token: "t", user: User(id: "u1", username: "ivy")))
        defaults.set(["x"], forKey: "ivy.lib.\(ref.id).shelf")
        c.remove(ref.id)
        #expect(c.libraries.isEmpty && c.active == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try c.credentials(for: ref.id).load() == nil)
        #expect(defaults.object(forKey: "ivy.lib.\(ref.id).shelf") == nil)
    }

    @Test func signedInRecordsTheAccount() {
        let c = catalog()
        let ref = c.createServer(server, name: "Work")
        c.signedIn(ref.id, user: User(id: "u1", username: "ivy"))
        #expect(c.library(ref.id)?.account == "ivy")
        #expect(c.library(ref.id)?.userID == "u1")
    }

    @Test func legacyAccountBecomesAServerLibrary() throws {
        let account = StoredAccount(server: server, token: "tok", user: User(id: "u1", username: "ivy"))
        let oldURL = LocalStore.url(for: account, in: root)
        do {
            let s = try LocalStore(url: oldURL)
            try s.setMeta("cursor", Int64(42))
        }
        let legacy = InMemoryCredentialStore(account)

        let c = catalog()
        c.migrateLegacy(from: legacy)
        let ref = try #require(c.active)
        #expect(ref.kind == .server && ref.server == server && ref.userID == "u1")
        #expect(try c.credentials(for: ref.id).load() == account)
        #expect(try legacy.load() == nil)
        let moved: Int64? = try LocalStore(url: c.storeURL(for: ref.id)).meta("cursor")
        #expect(moved == 42)

        // Runs once: a later start with a list leaves it alone.
        let other = InMemoryCredentialStore(account)
        catalog().migrateLegacy(from: other)
        #expect(catalog().libraries.count == 1)
    }

    @Test func signedOutLegacyDatabaseIsFoundByItsShelfState() throws {
        let account = StoredAccount(server: server, token: "", user: User(id: "u1", username: ""))
        _ = try LocalStore(url: LocalStore.url(for: account, in: root))
        defaults.set(["f1"], forKey: "ivy.shelf.expanded.\(server)|u1")
        defaults.set(["f2"], forKey: "ivy.shelf.expanded.https://gone.example.com|u2") // no database: skipped

        let c = catalog()
        c.migrateLegacy(from: InMemoryCredentialStore())
        let ref = try #require(c.active)
        #expect(c.libraries.count == 1)
        #expect(ref.server == server && ref.userID == "u1" && ref.account == nil)
        #expect(try c.credentials(for: ref.id).load() == nil)
        #expect(FileManager.default.fileExists(atPath: c.storeURL(for: ref.id).path))
        #expect(defaults.stringArray(forKey: "ivy.lib.\(ref.id).expanded") == ["f1"])
    }

    @Test func freshInstallMigratesNothing() {
        let c = catalog()
        c.migrateLegacy(from: InMemoryCredentialStore())
        #expect(c.libraries.isEmpty)
    }
}

@MainActor
@Suite struct LocalLibraryTests {
    @Test func editsAreSavedButNeverQueued() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ivy-\(UUID())/library.sqlite")
        defer { LocalStore.remove(at: url) }
        do {
            let e = SyncEngine(store: try LocalStore(url: url), transport: nil, device: "d")
            #expect(e.isLocal)
            let f = e.createFolder(name: "Inbox")
            let n = e.createNote(title: "local", folderId: f.id)
            e.updateNote(n.id, .init(body: "hello"))
            let gone = e.createNote(title: "gone")
            e.deleteNote(gone.id)
            await e.sync()
            #expect(e.state.pending == 0 && e.state.status == .idle)
            e.persistNow()
        }
        let e = SyncEngine(store: try LocalStore(url: url), transport: nil, device: "d")
        try e.load()
        #expect(e.notes.values.map(\.title) == ["local"])
        #expect(e.notes.values.first?.body == "hello")
        #expect(e.folders.count == 1)
        #expect(e.outbox.isEmpty)
    }
}
