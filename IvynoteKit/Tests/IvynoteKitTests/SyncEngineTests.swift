import Foundation
import Testing
@testable import IvynoteKit

/// A scripted server: records pushes and answers with queued responses.
final class FakeSync: SyncTransport, @unchecked Sendable {
    private let lock = NSLock()
    var snapshots: [PullResponse] = []
    var pulls: [PullResponse] = []
    var pushHandler: @Sendable ([Change]) throws -> PushResponse = { changes in
        PushResponse(results: changes.enumerated().map { i, c in
            ChangeResult(type: c.type, id: c.id, ok: true, seq: Int64(i + 1), rev: c.type == .note && c.fields?["body"] != nil ? (c.baseRev ?? 0) + 1 : nil)
        }, seq: Int64(changes.count))
    }
    private(set) var pushed: [[Change]] = []
    private(set) var calls: [String] = []
    var uploadHandler: @Sendable (Data, String, String) throws -> Attachment = { data, name, mime in
        Attachment(id: "srv" + String(name.filter(\.isLetter).prefix(8)).padding(toLength: 8, withPad: "x", startingAt: 0),
                   name: name, mime: mime, size: Int64(data.count), createdAt: 1, updatedAt: 1)
    }
    private(set) var uploaded: [String] = []

    func uploadFile(_ data: Data, name: String, mime: String) async throws -> Attachment {
        let handler = lock.withLock { uploaded.append(name); calls.append("upload:\(name)"); return uploadHandler }
        return try handler(data, name, mime)
    }

    func snapshot() async throws -> PullResponse {
        lock.withLock { calls.append("snapshot"); return snapshots.isEmpty ? PullResponse(seq: 0) : snapshots.removeFirst() }
    }
    func pull(since: Int64) async throws -> PullResponse {
        lock.withLock { calls.append("pull:\(since)"); return pulls.isEmpty ? PullResponse(seq: since) : pulls.removeFirst() }
    }
    func push(_ changes: [Change]) async throws -> PushResponse {
        let handler = lock.withLock { pushed.append(changes); calls.append("push:\(changes.count)"); return pushHandler }
        return try handler(changes)
    }
}

@MainActor
@Suite struct SyncEngineTests {
    var clock: Millis = 1_800_000_000_000
    func engine(_ fake: FakeSync, store: LocalStore? = nil) throws -> SyncEngine {
        let t = clock
        return SyncEngine(store: try store ?? LocalStore(url: nil), transport: fake, device: "test-1",
                          debounce: .seconds(3600), persistDelay: .seconds(3600), now: { t })
    }

    func note(_ id: String, title: String = "", body: String = "", rev: Int64 = 1, seq: Int64 = 1, deleted: Bool = false) -> Note {
        Note(id: id, title: title, body: body, rev: rev, seq: seq, deleted: deleted, createdAt: 1, updatedAt: 1)
    }

    @Test func firstSyncDownloadsSnapshotThenPulls() async throws {
        let fake = FakeSync()
        fake.snapshots = [PullResponse(seq: 7, folders: [Folder(id: "f1234567", name: "Work", seq: 1, createdAt: 1, updatedAt: 1)],
                                       notes: [note("n0000001", title: "Hello")])]
        let e = try engine(fake)
        await e.sync()
        #expect(e.notes["n0000001"]?.title == "Hello")
        #expect(e.folders["f1234567"]?.name == "Work")
        #expect(e.cursor == 7)
        #expect(e.state.status == .idle && e.state.lastSyncAt > 0)
        await e.sync()
        #expect(fake.calls == ["snapshot", "pull:7"])
    }

    @Test func localEditsArePushedWithBaseRev() async throws {
        let fake = FakeSync()
        fake.snapshots = [PullResponse(seq: 1, notes: [note("n0000001", body: "a", rev: 3)])]
        let e = try engine(fake)
        await e.sync()
        e.updateNote("n0000001", .init(body: "b"))
        #expect(e.state.pending == 1)
        await e.sync()
        let change = try #require(fake.pushed.last?.first)
        #expect(change.baseRev == 3)
        #expect(change.fields?["body"] == .string("b"))
        #expect(change.device == "test-1")
        #expect(e.notes["n0000001"]?.rev == 4)
        #expect(e.state.pending == 0)
    }

    @Test func newNotesPushAllFieldsWithBaseRevZero() async throws {
        let fake = FakeSync()
        let e = try engine(fake)
        let n = e.createNote(title: "T", body: "B", folderId: "f1234567")
        await e.sync()
        let c = try #require(fake.pushed.first?.first)
        #expect(c.id == n.id && c.op == .upsert && c.baseRev == 0)
        #expect(c.fields?["title"] == .string("T"))
        #expect(c.fields?["folderId"] == .string("f1234567"))
        #expect(c.fields?["createdAt"] == .int(clock))
    }

    @Test func pendingFieldsSurviveAPull() async throws {
        let fake = FakeSync()
        fake.snapshots = [PullResponse(seq: 1, notes: [note("n0000001", title: "old", body: "x")])]
        let e = try engine(fake)
        await e.sync()
        e.updateNote("n0000001", .init(title: "mine"))
        // A pull arrives while the edit is unpushed: title stays local, body updates.
        e.applyPull(PullResponse(seq: 2, notes: [note("n0000001", title: "theirs", body: "y", rev: 2, seq: 2)]), snapshot: false)
        #expect(e.notes["n0000001"]?.title == "mine")
        #expect(e.notes["n0000001"]?.body == "y")
    }

    @Test func tombstonesWinOverPendingEdits() async throws {
        let fake = FakeSync()
        fake.snapshots = [PullResponse(seq: 1, notes: [note("n0000001")])]
        let e = try engine(fake)
        await e.sync()
        e.updateNote("n0000001", .init(title: "edit"))
        e.applyPull(PullResponse(seq: 2, notes: [note("n0000001", seq: 2, deleted: true)]), snapshot: false)
        #expect(e.notes["n0000001"] == nil)
        #expect(e.state.pending == 0)
    }

    @Test func snapshotDropsWhatTheServerNoLongerHas() async throws {
        let fake = FakeSync()
        let e = try engine(fake)
        e.applyPull(PullResponse(seq: 1, notes: [note("n0000001"), note("n0000002")]), snapshot: true)
        let mine = e.createNote(title: "unpushed")
        e.applyPull(PullResponse(seq: 2, notes: [note("n0000002")]), snapshot: true)
        #expect(e.notes["n0000001"] == nil)
        #expect(e.notes["n0000002"] != nil)
        #expect(e.notes[mine.id] != nil) // still in the outbox
    }

    @Test func editsDuringAPushStayQueued() async throws {
        let fake = FakeSync()
        fake.snapshots = [PullResponse(seq: 1, notes: [note("n0000001", body: "a", rev: 1)])]
        let e = try engine(fake)
        await e.sync()
        e.updateNote("n0000001", .init(body: "b"))
        let sent = e.outbox["note:n0000001"]!
        e.updateNote("n0000001", .init(body: "c")) // typed while "b" was in flight
        e.applyResult(sent: sent, ChangeResult(type: .note, id: "n0000001", ok: true, seq: 2, rev: 2))
        let cur = try #require(e.outbox["note:n0000001"])
        #expect(cur.fields["body"] == .string("c"))
        #expect(cur.baseRev == 2) // builds on the accepted "b"
        #expect(e.notes["n0000001"]?.rev == 2)
    }

    @Test func mergedBodyReplacesLocalText() async throws {
        let fake = FakeSync()
        fake.snapshots = [PullResponse(seq: 1, notes: [note("n0000001", body: "A\nB\n", rev: 1)])]
        fake.pushHandler = { c in PushResponse(results: [ChangeResult(type: .note, id: c[0].id, ok: true, seq: 3, rev: 3, merged: true, body: "A\nb\nC\n")], seq: 3) }
        let e = try engine(fake)
        await e.sync()
        e.updateNote("n0000001", .init(body: "A\nb\n"))
        await e.sync()
        #expect(e.notes["n0000001"]?.body == "A\nb\nC\n")
        #expect(e.notes["n0000001"]?.rev == 3)
    }

    @Test func conflictCopyIsReported() async throws {
        let fake = FakeSync()
        fake.snapshots = [PullResponse(seq: 1, notes: [note("n0000001", body: "a", rev: 1)])]
        fake.pushHandler = { c in PushResponse(results: [ChangeResult(type: .note, id: c[0].id, ok: true, seq: 4, rev: 2, conflictCopy: "copy0001")], seq: 4) }
        let e = try engine(fake)
        await e.sync()
        e.updateNote("n0000001", .init(body: "mine"))
        await e.sync()
        #expect(e.conflict == ConflictNotice(noteID: "n0000001", copyID: "copy0001"))
    }

    @Test func refusedChangesAreBlockedNotLost() async throws {
        let fake = FakeSync()
        fake.pushHandler = { c in PushResponse(results: [ChangeResult(type: c[0].type, id: c[0].id, ok: false, error: "invalid hlc")], seq: 0) }
        let e = try engine(fake)
        e.createFolder(name: "X")
        await e.sync()
        #expect(e.state.blocked == 1 && e.state.pending == 0)
        await e.sync()
        #expect(fake.pushed.count == 1) // not sent again until edited or restarted
    }

    @Test func badBatchesAreSplitToFindTheCulprit() async throws {
        let fake = FakeSync()
        fake.pushHandler = { changes in
            if changes.contains(where: { $0.fields?["name"] == .string("bad") }) {
                throw APIError.server(status: 400, message: "name too long")
            }
            return PushResponse(results: changes.map { ChangeResult(type: $0.type, id: $0.id, ok: true, seq: 1) }, seq: 1)
        }
        let e = try engine(fake)
        e.createFolder(name: "a"); e.createFolder(name: "bad"); e.createFolder(name: "c")
        await e.sync()
        #expect(e.state.blocked == 1)
        #expect(e.state.pending == 0)
    }

    @Test func pushesInTheOrderEntitiesWereTouched() async throws {
        let fake = FakeSync()
        var t: Millis = 1000
        let e = SyncEngine(store: try LocalStore(url: nil), transport: fake, device: "d",
                           debounce: .seconds(3600), persistDelay: .seconds(3600), now: { t += 1; return t })
        let f = e.createFolder(name: "New")
        let n = e.createNote(title: "in it", folderId: f.id)
        e.renameFolder(f.id, to: "Renamed") // later edit, but the folder still goes first
        await e.sync()
        #expect(fake.pushed[0].map(\.id) == [f.id, n.id])
    }

    @Test func deletingAFolderTrashesItsNotesAndSubfolders() throws {
        let e = try engine(FakeSync())
        let top = e.createFolder(name: "Top")
        let sub = e.createFolder(name: "Sub", parentId: top.id)
        let n = e.createNote(title: "x", folderId: sub.id)
        e.deleteFolder(top.id)
        #expect(e.folders.isEmpty)
        #expect(e.notes[n.id]?.isTrashed == true)
        #expect(e.notes[n.id]?.folderId == "")
        #expect(e.outbox["folder:\(top.id)"]?.op == .delete)
    }

    @Test func folderCyclesAreRefused() throws {
        let e = try engine(FakeSync())
        let a = e.createFolder(name: "A")
        let b = e.createFolder(name: "B", parentId: a.id)
        #expect(!e.canMoveFolder(a.id, to: b.id))
        e.moveFolder(a.id, to: b.id)
        #expect(e.folders[a.id]?.parentId == "")
    }

    @Test func networkFailureMeansOfflineAndKeepsChanges() async throws {
        let fake = FakeSync()
        fake.pushHandler = { _ in throw APIError.unreachable("offline") }
        let e = try engine(fake)
        e.createNote(title: "offline note")
        await e.sync()
        #expect(e.state.status == .offline)
        #expect(e.state.pending == 1)
    }

    @Test func unauthorizedIsReported() async throws {
        let fake = FakeSync()
        fake.pushHandler = { _ in throw APIError.server(status: 401, message: "") }
        let e = try engine(fake)
        var told = false
        e.onUnauthorized = { told = true }
        e.createNote()
        await e.sync()
        #expect(told)
        #expect(e.state.pending == 1) // kept for after signing in again
    }

    @Test func everythingSurvivesARestart() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ivy-\(UUID())/library.sqlite")
        defer { LocalStore.remove(at: url) }
        let fake = FakeSync()
        fake.snapshots = [PullResponse(seq: 5, notes: [note("n0000001", title: "synced")])]
        do {
            let e = try engine(fake, store: LocalStore(url: url))
            await e.sync()
            e.createNote(title: "draft")
            e.persistNow()
        }
        let e = try engine(fake, store: LocalStore(url: url))
        try e.load()
        #expect(e.cursor == 5)
        #expect(Set(e.notes.values.map(\.title)) == ["synced", "draft"])
        #expect(e.state.pending == 1)
    }
}
