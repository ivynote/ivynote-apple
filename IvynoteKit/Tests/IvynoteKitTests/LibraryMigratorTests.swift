import Foundation
import Testing
@testable import IvynoteKit

@Suite struct SyncRegionTests {
    @Test func picksTheNodeByWhereTheDeviceIs() {
        #expect(SyncRegion.preferred(storefront: "CHN", region: "US") == .cn)
        #expect(SyncRegion.preferred(storefront: "USA", region: "CN") == .global)
        #expect(SyncRegion.preferred(storefront: nil, region: "CN") == .cn)
        #expect(SyncRegion.preferred(storefront: nil, region: "HK") == .global)
        #expect(SyncRegion.preferred(storefront: nil, region: nil, timeZone: "Asia/Shanghai") == .cn)
        #expect(SyncRegion.preferred(storefront: nil, region: nil, timeZone: "Asia/Taipei") == .global)
        #expect(SyncRegion.preferred(storefront: nil, region: nil, timeZone: nil) == .global)
    }

    @Test func mapsServersToRegions() throws {
        #expect(SyncRegion.cn.server.description == "https://web.ivynote.net")
        #expect(SyncRegion.of(try ServerAddress(parsing: "web.ivynote.app/")) == .global)
        #expect(SyncRegion.of(try ServerAddress(parsing: "notes.example.com")) == nil)
        #expect(SyncRegion.of(nil) == nil)
    }

    @Test func takesAddressesFromTheWebsite() throws {
        let defaults = UserDefaults(suiteName: "regions-\(UUID().uuidString)")!
        let dir = RegionDirectory(defaults: defaults)
        let temp = try ServerAddress(parsing: "https://ivynote.frytea.com")
        #expect(dir.server(for: .cn) == SyncRegion.cn.builtInServer)

        #expect(dir.apply(Data(#"{"regions":[{"id":"cn","url":"https://IvyNote.Frytea.com/"},{"id":"mars","url":"https://mars.example"}]}"#.utf8)))
        #expect(dir.server(for: .cn) == temp)
        #expect(dir.server(for: .global) == SyncRegion.global.builtInServer)
        #expect(dir.region(of: temp) == .cn)
        #expect(dir.region(of: SyncRegion.cn.builtInServer) == .cn)
        // Kept for the next start.
        #expect(RegionDirectory(defaults: defaults).server(for: .cn) == temp)

        // Back to the filed domain: the temporary one, listed as an alias, stays official.
        #expect(dir.apply(Data(#"{"regions":[{"id":"cn","url":"https://web.ivynote.net","aliases":["https://ivynote.frytea.com"]}]}"#.utf8)))
        #expect(dir.server(for: .cn) == SyncRegion.cn.builtInServer)
        #expect(dir.region(of: temp) == .cn)

        // Unusable answers change nothing.
        #expect(!dir.apply(Data(#"{"regions":[{"id":"cn","url":"http://insecure.example"}]}"#.utf8)))
        #expect(!dir.apply(Data("nope".utf8)))
        #expect(dir.server(for: .cn) == SyncRegion.cn.builtInServer)
    }
}

@Suite struct LibraryMigratorTests {
    let server = try! ServerAddress(parsing: "https://web.ivynote.net")
    static let empty = #"{"seq":0,"notes":[],"folders":[],"tags":[],"attachments":[]}"#

    func content() -> LibraryMigrator.Content {
        LibraryMigrator.Content(
            folders: [Folder(id: "child", parentId: "root", name: "Child", createdAt: 1, updatedAt: 1),
                      Folder(id: "root", name: "Root", createdAt: 1, updatedAt: 1)],
            tags: [Tag(id: "t1", name: "work", createdAt: 1, updatedAt: 1)],
            notes: [Note(id: "n1", folderId: "child", title: "Hello", body: "hi", tags: ["t1"], createdAt: 1000, updatedAt: 2000),
                    Note(id: "n2", title: "Old", createdAt: 1000, updatedAt: 2000)])
    }

    @Test func pushesEverythingWithItsOwnIDs() async throws {
        let t = StubTransport([
            "GET /api/v1/sync/pull": .json(200, Self.empty),
            "POST /api/v1/sync/push": .json(200, #"{"seq":5,"results":[{"type":"folder","id":"root","ok":true},{"type":"folder","id":"child","ok":true},{"type":"tag","id":"t1","ok":true},{"type":"note","id":"n1","ok":true},{"type":"note","id":"n2","ok":false,"error":"invalid"}]}"#),
        ])
        var c = content()
        c.notes[0].pinned = true
        c.notes[1].trashedAt = 5
        let migrator = LibraryMigrator(api: APIClient(server: server, token: "tok", transport: t), device: "ios-test", now: { 1_790_000_000_000 })
        let result = try await migrator.run(c)
        #expect(result.notes == 1)
        #expect(result.rejected == ["note:n2 invalid"])

        let push = try #require(t.sent.first(where: { $0.url!.path() == "/api/v1/sync/push" }))
        #expect(push.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        struct Body: Decodable { var changes: [Change] }
        let changes = try JSONDecoder().decode(Body.self, from: push.httpBody!).changes
        #expect(changes.map { "\($0.type.rawValue):\($0.id)" } == ["folder:root", "folder:child", "tag:t1", "note:n1", "note:n2"])
        let n1 = changes[3]
        #expect(n1.baseRev == 0 && n1.device == "ios-test")
        #expect(n1.fields?["folderId"] == .string("child"))
        #expect(n1.fields?["tags"] == .array([.string("t1")]))
        #expect(n1.fields?["pinned"] == .bool(true))
        #expect(n1.fields?["createdAt"] == .int(1000))
        #expect(changes[4].fields?["trashed"] == .bool(true))
        #expect(changes.map(\.hlc) == changes.map(\.hlc).sorted())
    }

    @Test func refusesAnAccountWithOtherNotes() async throws {
        let t = StubTransport(["GET /api/v1/sync/pull": .json(200, #"{"seq":3,"notes":[{"id":"someone","title":"x","body":"","rev":1,"seq":3,"createdAt":1,"updatedAt":1}]}"#)])
        let migrator = LibraryMigrator(api: APIClient(server: server, token: "tok", transport: t), device: "ios-test")
        await #expect(throws: LibraryMigrator.Failure.accountNotEmpty) { try await migrator.run(content()) }
        #expect(!t.sent.contains(where: { $0.url!.path() == "/api/v1/sync/push" }))
    }

    @Test func resumesIntoAnAccountHoldingOnlyItsOwnNotes() async throws {
        let t = StubTransport([
            "GET /api/v1/sync/pull": .json(200, #"{"seq":3,"notes":[{"id":"n1","title":"Hello","body":"hi","rev":1,"seq":3,"createdAt":1,"updatedAt":1}]}"#),
            "POST /api/v1/sync/push": .json(200, #"{"seq":5,"results":[]}"#),
        ])
        let migrator = LibraryMigrator(api: APIClient(server: server, token: "tok", transport: t), device: "ios-test")
        _ = try await migrator.run(content())
        #expect(t.sent.contains(where: { $0.url!.path() == "/api/v1/sync/push" }))
    }

    @Test func readsALibraryDatabase() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ivy-mig-\(UUID())/library.sqlite")
        defer { LocalStore.remove(at: url) }
        do {
            let store = try LocalStore(url: url)
            try store.put(.notes, [(id: "n1", value: Note(id: "n1", title: "A", createdAt: 1, updatedAt: 1))])
            try store.put(.folders, [(id: "f1", value: Folder(id: "f1", name: "F", createdAt: 1, updatedAt: 1))])
        }
        let c = try LibraryMigrator.Content.read(from: url)
        #expect(c.notes.map(\.id) == ["n1"] && c.folders.map(\.id) == ["f1"] && c.tags.isEmpty)
    }
}

@MainActor
@Suite struct LibraryCatalogSyncTests {
    let server = try! ServerAddress(parsing: "https://web.ivynote.app")
    let defaults = UserDefaults(suiteName: "ivy.tests.\(UUID().uuidString)")!
    let root = FileManager.default.temporaryDirectory.appending(path: "ivy-cat-\(UUID())")
    let box = CredentialBox()

    func catalog() -> LibraryCatalog {
        LibraryCatalog(defaults: defaults, root: root, credentials: box.store)
    }

    @Test func createsALibraryOnlyWithItsSignIn() throws {
        let c = catalog()
        let user = User(id: "u1", username: "ivy")
        let ref = try c.createSignedIn(server, name: "我的笔记", token: "tok", user: user)
        #expect(c.activeID == ref.id)
        #expect(ref.account == "ivy" && ref.userID == "u1" && ref.server == server)
        #expect(try c.credentials(for: ref.id).load()?.token == "tok")
    }

    @Test func marksALocalLibraryAsMoved() throws {
        let c = catalog()
        let local = c.createLocal(name: "Mine")
        #expect(local.canTurnOnSync)
        c.turnOnSync(local.id)
        #expect(c.active == nil && c.pendingSync == local.id)
        let synced = try c.createSignedIn(server, name: "Mine", token: "tok", user: User(id: "u1", username: "ivy"))
        c.markMigrated(local.id, to: synced.id)
        c.markMigrated(synced.id, to: local.id)
        #expect(c.library(local.id)?.migratedTo == synced.id)
        #expect(c.library(local.id)?.canTurnOnSync == false)
        #expect(c.library(synced.id)?.migratedTo == nil)
        // Persists, and older lists without the field still load.
        #expect(catalog().library(local.id)?.migratedTo == synced.id)
    }
}
