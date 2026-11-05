import Foundation
import Testing
@testable import IvynoteKit

/// Runs against a real Ivynote server when `IVY_TEST_SERVER` is set, e.g.
/// `IVY_TEST_SERVER=http://127.0.0.1:18080 swift test`. Registers a throwaway
/// account, so point it at a disposable server only.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["IVY_TEST_SERVER"] != nil))
struct LiveServerTests {
    @Test func accountLifecycle() async throws {
        let server = try ServerAddress(parsing: ProcessInfo.processInfo.environment["IVY_TEST_SERVER"]!)
        let api = APIClient(server: server)

        let info = try await api.probe()
        #expect(!info.version.isEmpty)

        let username = "apple\(Int.random(in: 1000...9999))"
        let password = "test-password-1"
        let registered: (token: String, user: User)
        if info.canRegister {
            registered = try await api.register(username: username, password: password, email: "", displayName: "Apple Test")
        } else {
            Issue.record("server does not allow registration; use an empty server")
            return
        }
        #expect(registered.user.username == username)

        let me = try await api.authorized(registered.token).me()
        #expect(me.id == registered.user.id)

        try await api.authorized(registered.token).logout()
        do {
            _ = try await api.authorized(registered.token).me()
            Issue.record("revoked token still works")
        } catch let e as APIError {
            #expect(e.endsSession)
        }

        do {
            _ = try await api.login(identity: username, password: "wrong-password")
            Issue.record("wrong password accepted")
        } catch let e as APIError {
            #expect(e.status == 401)
        }

        let again = try await api.login(identity: username, password: password)
        #expect(try await api.authorized(again.token).me().username == username)
    }
}

/// Two devices syncing through a real server.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["IVY_TEST_SERVER"] != nil))
struct LiveSyncTests {
    func device(_ name: String, _ api: APIClient) throws -> SyncEngine {
        SyncEngine(store: try LocalStore(url: nil), transport: api, device: name,
                   debounce: .seconds(3600), persistDelay: .seconds(3600))
    }

    @Test func twoDevicesConverge() async throws {
        let server = try ServerAddress(parsing: ProcessInfo.processInfo.environment["IVY_TEST_SERVER"]!)
        let anon = APIClient(server: server)
        let auth = try await anon.register(username: "sync\(Int.random(in: 10000...99999))", password: "test-password-1", email: "", displayName: "")
        let api = anon.authorized(auth.token)
        let a = try device("test-a", api), b = try device("test-b", api)

        // Create on A, see it on B, in the right folder.
        let folder = a.createFolder(name: "Work")
        let note = a.createNote(title: "Plan", body: "one\ntwo\nthree\n", folderId: folder.id)
        await a.sync()
        #expect(a.state.status == .idle && a.state.pending == 0)
        await b.sync()
        #expect(b.notes[note.id]?.body == "one\ntwo\nthree\n")
        #expect(b.notes[note.id]?.folderId == folder.id)
        #expect(b.folders[folder.id]?.name == "Work")

        // Concurrent edits to different lines merge.
        a.updateNote(note.id, .init(body: "ONE\ntwo\nthree\n"))
        b.updateNote(note.id, .init(body: "one\ntwo\nTHREE\n"))
        await a.sync()
        await b.sync()
        await a.sync()
        #expect(a.notes[note.id]?.body == "ONE\ntwo\nTHREE\n")
        #expect(b.notes[note.id]?.body == "ONE\ntwo\nTHREE\n")
        #expect(a.notes[note.id]?.rev == b.notes[note.id]?.rev)

        // Metadata: last writer wins per field.
        b.updateNote(note.id, .init(title: "Plan v2", pinned: true))
        await b.sync()
        await a.sync()
        #expect(a.notes[note.id]?.title == "Plan v2")
        #expect(a.notes[note.id]?.pinned == true)

        // The same line edited on both: the server keeps a conflict copy.
        a.updateNote(note.id, .init(body: "A wins\ntwo\nTHREE\n"))
        b.updateNote(note.id, .init(body: "B wins\ntwo\nTHREE\n"))
        await a.sync()
        await b.sync()
        let conflict = try #require(b.conflict)
        await a.sync()
        await b.sync()
        #expect(b.notes[note.id]?.body == "A wins\ntwo\nTHREE\n")
        #expect(a.notes[conflict.copyID]?.body == "B wins\ntwo\nTHREE\n")
        #expect(b.notes[conflict.copyID]?.title.contains("Plan v2") == true)

        // Trash, then delete for good.
        a.updateNote(note.id, .init(trashed: true))
        await a.sync()
        await b.sync()
        #expect(b.notes[note.id]?.isTrashed == true)
        b.deleteNote(note.id)
        await b.sync()
        await a.sync()
        #expect(a.notes[note.id] == nil)

        // Deleting the folder trashes what is in it, on both devices.
        let inside = b.createNote(title: "Inside", folderId: folder.id)
        await b.sync()
        await a.sync()
        a.deleteFolder(folder.id)
        await a.sync()
        await b.sync()
        #expect(b.folders[folder.id] == nil)
        #expect(b.notes[inside.id]?.isTrashed == true)

        // A fresh device gets everything from a snapshot.
        let c = try device("test-c", api)
        await c.sync()
        #expect(Set(c.notes.keys) == Set(a.notes.keys))
        #expect(c.cursor == a.cursor)
    }

    @Test func eventsAnnounceChanges() async throws {
        let server = try ServerAddress(parsing: ProcessInfo.processInfo.environment["IVY_TEST_SERVER"]!)
        let anon = APIClient(server: server)
        let auth = try await anon.register(username: "sse\(Int.random(in: 10000...99999))", password: "test-password-1", email: "", displayName: "")
        let api = anon.authorized(auth.token)
        let stream = SyncEvents(api: api).stream()
        var it = stream.makeAsyncIterator()
        let first = try await it.next()
        #expect(first == 0)
        let a = try device("test-a", api)
        a.createNote(title: "ping")
        await a.sync()
        let next = try await it.next()
        #expect((next ?? 0) > 0)
    }
}
