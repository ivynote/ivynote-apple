import Foundation
import Testing
@testable import IvynoteKit

@MainActor
@Suite struct UploadQueueTests {
    func engine(_ fake: FakeSync?, now: @escaping () -> Millis = { 1_800_000_000_000 }) throws -> SyncEngine {
        SyncEngine(store: try LocalStore(url: nil), transport: fake, device: "test-1",
                   debounce: .seconds(3600), persistDelay: .seconds(3600), cacheSettings: nil, now: now)
    }

    @Test func insertsLocallyFirstThenUploadsAndPromotesToCache() async throws {
        let fake = FakeSync()
        fake.snapshots = [PullResponse(seq: 1)]
        let e = try engine(fake)
        await e.sync()

        var normalized: [(local: String, remote: String)] = []
        e.onResourceNormalized = { localID, att in
            normalized.append((localID, att.id))
        }

        // Inserting a file stages locally right away without hitting the network.
        let bytes = Data("png-bytes".utf8)
        let f = try await e.addFile(bytes, name: "photo.png", mime: "image/png")
        #expect(f.local && f.id.hasPrefix("local-"))
        #expect(f.markdown == "![photo.png](ivy://res/\(f.id))")
        #expect(e.uploads[f.id] != nil && e.state.uploads == 1)
        #expect(fake.uploaded.isEmpty)
        let localCopy = try #require(e.localAttachment(f.id))
        #expect(try Data(contentsOf: localCopy.url) == bytes)

        let note = e.createNote(title: "T", body: "look \(f.markdown)\n")
        fake.uploadHandler = { data, name, mime in
            Attachment(id: "att00000099", name: name, mime: mime, size: Int64(data.count), createdAt: 1, updatedAt: 1)
        }

        let syncStart = fake.calls.count
        await e.sync()
        #expect(e.uploads.isEmpty && e.state.uploads == 0)
        #expect(e.attachments["att00000099"]?.kind == "image")
        #expect(e.notes[note.id]?.body == "look ![photo.png](ivy://res/att00000099)\n")
        #expect(normalized.count == 1 && normalized[0].local == f.id && normalized[0].remote == "att00000099")
        // Staging upload file was removed, and the bytes were promoted into the synced local cache.
        #expect(!FileManager.default.fileExists(atPath: localCopy.url.path))
        let cached = try #require(e.localAttachment("att00000099"))
        #expect(try Data(contentsOf: cached.url) == bytes)
        // Old `local-` ID also resolves via runtime alias without re-downloading.
        let viaAlias = try #require(e.localAttachment(f.id))
        #expect(try Data(contentsOf: viaAlias.url) == bytes)
        // Requesting a thumbnail falls back to the cached full file.
        let thumbFallback = try #require(e.localAttachment("att00000099", thumb: true))
        #expect(try Data(contentsOf: thumbFallback.url) == bytes)
        // Uploaded before push, so the pushed note body already carries the normalized server ID.
        #expect(Array(fake.calls[syncStart...]) == ["upload:photo.png", "push:1", "pull:1"])
        let pushed = try #require(fake.pushed.last?.first)
        #expect(pushed.fields?["body"] == .string("look ![photo.png](ivy://res/att00000099)\n"))
    }

    @Test func deduplicatesIdenticalPendingUploads() async throws {
        let fake = FakeSync()
        let e = try engine(fake)
        let bytes = Data("same-image-data".utf8)
        let first = try await e.addFile(bytes, name: "a.png", mime: "image/png")
        let second = try await e.addFile(bytes, name: "b.png", mime: "image/png")
        #expect(first.id == second.id)
        #expect(e.uploads.count == 1)
        #expect(second.name == "b.png")
    }

    @Test func queuesOfflineAndReplacesTheLocalID() async throws {
        let fake = FakeSync()
        // Start from a downloaded library so recovery uses an incremental pull.
        fake.snapshots = [PullResponse(seq: 1)]
        let e = try engine(fake)
        await e.sync()
        fake.uploadHandler = { _, _, _ in throw APIError.unreachable("offline") }
        let f = try await e.addFile(Data("report".utf8), name: "report.pdf", mime: "application/pdf")
        #expect(f.local && f.id.hasPrefix("local-"))
        #expect(f.markdown == "[report.pdf](ivy://res/\(f.id))")
        #expect(e.state.uploads == 1)
        let copy = try #require(e.uploadFile(f.id))
        #expect(try Data(contentsOf: copy.url) == Data("report".utf8))
        let note = e.createNote(title: "T", body: "see \(f.markdown)\n")

        // Offline sync fails gracefully and keeps the file queued.
        await e.sync()
        #expect(e.state.status == .offline)
        #expect(e.uploads.count == 1)

        fake.uploadHandler = { data, name, mime in
            Attachment(id: "att00000001", name: name, mime: mime, size: Int64(data.count), createdAt: 1, updatedAt: 1)
        }
        let recoveryStart = fake.calls.count
        await e.sync()
        #expect(e.uploads.isEmpty && e.state.uploads == 0)
        #expect(e.notes[note.id]?.body == "see [report.pdf](ivy://res/att00000001)\n")
        #expect(!FileManager.default.fileExists(atPath: copy.url.path))
        let cached = try #require(e.localAttachment("att00000001"))
        #expect(try Data(contentsOf: cached.url) == Data("report".utf8))
        // Uploaded before the push, so the body went out with the server's id.
        #expect(Array(fake.calls[recoveryStart...]) == ["upload:report.pdf", "push:1", "pull:1"])
        let pushed = try #require(fake.pushed.last?.first)
        #expect(pushed.fields?["body"] == .string("see [report.pdf](ivy://res/att00000001)\n"))
    }

    @Test func aRefusedFileStaysQueuedAndSyncGoesOn() async throws {
        let fake = FakeSync()
        let e = try engine(fake)
        let f = try await e.addFile(Data(count: 10), name: "big.mov", mime: "video/quicktime")
        e.createNote(title: "T", body: f.markdown)
        fake.uploadHandler = { _, _, _ in throw APIError.server(status: 413, message: "file too large") }
        await e.sync()
        #expect(e.uploads[f.id]?.failed != nil)
        #expect(e.uploadFailure?.name == "big.mov")
        #expect(e.state.status == .idle)
        #expect(!fake.pushed.isEmpty)
        // Not sent again in this run.
        let tries = fake.uploaded.count
        await e.sync()
        #expect(fake.uploaded.count == tries)
    }

    @Test func aServerErrorEndsTheRound() async throws {
        let fake = FakeSync()
        let e = try engine(fake)
        _ = try await e.addFile(Data(count: 3), name: "a.png", mime: "image/png")
        fake.uploadHandler = { _, _, _ in throw APIError.server(status: 503, message: "") }
        await e.sync()
        #expect(e.state.status == .offline)
        #expect(e.uploads.count == 1)
        #expect(fake.pushed.isEmpty)
    }

    @Test func aLocalLibraryKeepsItsFiles() async throws {
        let e = try engine(nil)
        let f = try await e.addFile(Data("x".utf8), name: "a.png", mime: "image/png")
        #expect(f.local)
        #expect(e.attachmentKind(f.id) == "image")
        await e.sync()
        #expect(e.uploads[f.id] != nil)
    }

    @Test func queuedFilesSurviveARestart() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ivy-up-\(UUID())/library.sqlite")
        defer { LocalStore.remove(at: url) }
        let fake = FakeSync()
        let id: String
        do {
            let e = SyncEngine(store: try LocalStore(url: url), transport: fake, device: "d", debounce: .seconds(3600), cacheSettings: nil)
            id = try await e.addFile(Data("x".utf8), name: "a.png", mime: "image/png").id
            e.stop()
        }
        let e = SyncEngine(store: try LocalStore(url: url), transport: fake, device: "d", debounce: .seconds(3600), cacheSettings: nil)
        try e.load()
        #expect(e.uploads[id]?.name == "a.png")
        #expect(e.uploadFile(id).map { FileManager.default.fileExists(atPath: $0.url.path) } == true)
    }

    @Test func noteEditingDoesNotCancelOrDelayBackgroundUploads() async throws {
        let fake = FakeSync()
        fake.uploadHandler = { data, name, mime in
            Attachment(id: "attbg00001", name: name, mime: mime, size: Int64(data.count), createdAt: 1, updatedAt: 1)
        }
        // Long note sync debounce (3600s), short independent upload delay (20ms).
        let e = SyncEngine(store: try LocalStore(url: nil), transport: fake, device: "test-bg",
                           debounce: .seconds(3600), persistDelay: .seconds(3600),
                           uploadDelay: .milliseconds(20), cacheSettings: nil)
        let f = try e.addFileLocal(Data("photo".utf8), name: "photo.jpg", mime: "image/jpeg")
        let note = e.createNote(title: "Draft", body: f.markdown)

        // Rapidly edit the note — this keeps resetting the sync debounce timer,
        // but must NOT cancel or delay the independent background upload worker.
        for i in 0..<6 {
            e.updateNote(note.id, .init(body: "\(f.markdown)\nedit \(i)"))
            try await Task.sleep(for: .milliseconds(10))
        }

        // Wait briefly for the independent background uploader to finish.
        for _ in 0..<40 where !e.uploads.isEmpty {
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(e.uploads.isEmpty)
        #expect(e.uploadStatus == .idle)
        #expect(e.attachments["attbg00001"] != nil)
        #expect(e.notes[note.id]?.body.contains("ivy://res/attbg00001") == true)
        e.stop()
    }

    @Test func networkRecoveryAutomaticallyResumesPendingUploads() async throws {
        let fake = FakeSync()
        fake.uploadHandler = { _, _, _ in throw APIError.unreachable("offline") }
        let e = SyncEngine(store: try LocalStore(url: nil), transport: fake, device: "test-net",
                           debounce: .seconds(3600), persistDelay: .seconds(3600),
                           uploadDelay: .milliseconds(10), cacheSettings: nil)
        let f = try e.addFileLocal(Data("offline-file".utf8), name: "doc.pdf", mime: "application/pdf")
        _ = await e.drainUploads()
        #expect(e.uploadStatus == .waitingForNetwork(remaining: 1))
        #expect(e.uploads[f.id] != nil)

        // Network returns: setNetworkReachable(true) must immediately resume
        // background uploads without waiting for backoff or manual sync().
        fake.uploadHandler = { data, name, mime in
            Attachment(id: "attnet0001", name: name, mime: mime, size: Int64(data.count), createdAt: 1, updatedAt: 1)
        }
        e.setNetworkReachable(true)

        for _ in 0..<40 where !e.uploads.isEmpty {
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(e.uploads.isEmpty)
        #expect(e.uploadStatus == .idle)
        #expect(e.attachments["attnet0001"] != nil)
        e.stop()
    }

    @Test func uploadStatusTracksRefusalAndRetry() async throws {
        let fake = FakeSync()
        fake.uploadHandler = { _, _, _ in throw APIError.server(status: 413, message: "too large") }
        let e = try engine(fake)
        _ = try e.addFileLocal(Data("big".utf8), name: "big.bin", mime: "application/octet-stream")
        _ = await e.drainUploads()
        #expect(e.uploadStatus == .failed(count: 1))

        fake.uploadHandler = { data, name, mime in
            Attachment(id: "attretry01", name: name, mime: mime, size: Int64(data.count), createdAt: 1, updatedAt: 1)
        }
        e.retryFailedUploads()
        for _ in 0..<40 where !e.uploads.isEmpty {
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(e.uploads.isEmpty)
        #expect(e.uploadStatus == .idle)
        #expect(e.attachments["attretry01"] != nil)
        e.stop()
    }

    @Test func editsTags() throws {
        let e = try engine(FakeSync())
        let t = e.createTag(name: "#work")
        #expect(t.name == "work")
        e.updateTag(t.id, name: " #job ", color: "blue")
        #expect(e.tags[t.id]?.name == "job" && e.tags[t.id]?.color == "blue")
        #expect(e.tag(named: "JOB")?.id == t.id)
        let entry = try #require(e.outbox["tag:\(t.id)"])
        #expect(entry.fields["name"] == .string("job"))
        #expect(entry.fields["color"] == .string("blue"))
    }
}

@MainActor
@Suite struct AttachmentCacheTests {
    @Test func evictsColdestEntriesWhenLimitExceeded() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ivy-cache-\(UUID())/library.sqlite")
        defer { LocalStore.remove(at: url) }
        var clock: Millis = 1_000_000
        let store = try LocalStore(url: url)
        let cache = AttachmentStore(store: store, settings: nil, localFirst: true, maxBytes: 250, now: { clock })
        try cache.load()

        _ = cache.store(id: "att00000001", data: Data(repeating: 1, count: 100), mime: "image/png")
        clock += 1000
        _ = cache.store(id: "att00000002", data: Data(repeating: 2, count: 100), mime: "image/png")
        #expect(cache.totalBytes == 200 && cache.entryCount == 2)

        // Access att00000001 repeatedly so it becomes hotter than att00000002.
        clock += 1000
        #expect(cache.cachedFile(id: "att00000001") != nil)
        clock += 1000
        #expect(cache.cachedFile(id: "att00000001") != nil)

        // Adding a third 100B file exceeds 250B; coldest (`att00000002`) is evicted.
        clock += 1000
        _ = cache.store(id: "att00000003", data: Data(repeating: 3, count: 100), mime: "image/png")
        #expect(cache.totalBytes == 200 && cache.entryCount == 2)
        #expect(cache.entry(id: "att00000001") != nil)
        #expect(cache.entry(id: "att00000002") == nil)
        #expect(cache.entry(id: "att00000003") != nil)

        // Lowering maxBytes immediately evicts down to the new cap.
        cache.applyPolicy(localFirst: true, maxBytes: 120)
        #expect(cache.totalBytes == 100 && cache.entryCount == 1)
        // `att00000001` had higher accessCount (heat bonus) so it stays warmest.
        #expect(cache.entry(id: "att00000001") != nil)
    }

    @Test func localFirstOffClearsSyncedCacheWithoutTouchingPendingUploads() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ivy-lf-\(UUID())/library.sqlite")
        defer { LocalStore.remove(at: url) }
        let fake = FakeSync()
        let e = SyncEngine(store: try LocalStore(url: url), transport: fake, device: "d", debounce: .seconds(3600), cacheSettings: nil)
        try e.load()

        _ = e.attachmentCache.store(id: "att00000001", data: Data("cached".utf8), mime: "image/png")
        let pending = try await e.addFile(Data("pending".utf8), name: "p.png", mime: "image/png")
        #expect(e.attachmentCache.entryCount == 1)
        #expect(e.uploads.count == 1)

        // Turning off local-first clears synced cache, but keeps pending uploads intact.
        e.attachmentCache.applyPolicy(localFirst: false, maxBytes: 500 * 1024 * 1024)
        #expect(e.attachmentCache.entryCount == 0 && e.attachmentCache.totalBytes == 0)
        #expect(e.localAttachment("att00000001") == nil)
        let stillPending = try #require(e.localAttachment(pending.id))
        #expect(try Data(contentsOf: stillPending.url) == Data("pending".utf8))
    }

    @Test func persistsAcrossRestartAndReconcilesOrphans() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ivy-persist-\(UUID())/library.sqlite")
        defer { LocalStore.remove(at: url) }
        let orphanFile: URL
        do {
            let store = try LocalStore(url: url)
            let cache = AttachmentStore(store: store, settings: nil, localFirst: true, maxBytes: 1024 * 1024)
            try cache.load()
            _ = cache.store(id: "att00000010", data: Data("hello".utf8), mime: "image/png")
            _ = cache.store(id: "att00000010", thumb: true, data: Data("hi".utf8), mime: "image/jpeg")
            orphanFile = cache.cacheDir.appending(path: "stray-file")
            try Data("orphan".utf8).write(to: orphanFile)
            cache.stop()
        }
        let store = try LocalStore(url: url)
        let cache = AttachmentStore(store: store, settings: nil, localFirst: true, maxBytes: 1024 * 1024)
        try cache.load()
        #expect(cache.entryCount == 2 && cache.totalBytes == 7)
        #expect(!FileManager.default.fileExists(atPath: orphanFile.path))
        let hit = try #require(cache.cachedFile(id: "att00000010"))
        #expect(try Data(contentsOf: hit.url) == Data("hello".utf8))
        // Removing attachment deletes both full and thumbnail cache entries.
        cache.remove(attachmentID: "att00000010")
        #expect(cache.entryCount == 0 && cache.totalBytes == 0)
    }

    @Test func settingsPropagateToAttachmentStore() throws {
        let suite = "ivy.test.cache.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AttachmentCacheSettings(defaults: defaults)
        #expect(settings.localFirst == true)
        #expect(settings.maxBytes == AttachmentCacheSettings.defaultMaxBytes)

        let url = FileManager.default.temporaryDirectory.appending(path: "ivy-set-\(UUID())/library.sqlite")
        defer { LocalStore.remove(at: url) }
        let cache = AttachmentStore(store: try LocalStore(url: url), settings: settings)
        try cache.load()
        _ = cache.store(id: "att11111111", data: Data(repeating: 7, count: 200), mime: "image/png")
        #expect(cache.totalBytes == 200)

        settings.maxBytes = 100
        #expect(cache.maxBytes == 100 && cache.totalBytes == 0)
        cache.stop()
    }
}

@Suite struct LinksTests {
    func note(_ id: String, _ title: String, _ body: String = "", updated: Millis = 1, trashed: Bool = false) -> Note {
        Note(id: id, title: title, body: body, trashedAt: trashed ? 1 : 0, createdAt: 1, updatedAt: updated)
    }

    @Test func parsesWikiLinks() {
        #expect(Links.parseWiki("Title#Part|alias") == .init(target: "Title", alias: "alias", heading: "Part"))
        #expect(Links.wikiTargets("[[ A  b ]] and [[c|x]] `[[code]]`\n```\n[[fenced]]\n```") == ["a b", "c"])
        #expect(Links.resourceRefs("![a](ivy://res/abcdefgh) `ivy://res/abcdefgh` [b](ivy://res/local-12345678)") == ["abcdefgh", "local-12345678"])
    }

    @Test func findsBacklinks() {
        let notes = [
            note("target01", "Target"),
            note("linker01", "By title", "see [[target]]", updated: 5),
            note("linker02", "By id", "[here](ivy://note/target01)", updated: 9),
            note("namesake", "Target", "[[Target]]", updated: 0), // older: its link goes to target01
            note("trashed1", "Gone", "[[Target]]", trashed: true),
            note("codeonly", "Code", "`[[Target]]`"),
        ]
        #expect(Links.backlinks(to: "target01", in: notes).map(\.id) == ["linker02", "linker01", "namesake"])
        #expect(Links.backlinks(to: "namesake", in: notes).isEmpty)
        // The newer of two notes with one title takes the [[title]] links.
        let newer = notes + [note("target02", "target", updated: 50)]
        #expect(Links.backlinks(to: "target01", in: newer).map(\.id) == ["linker02"])
    }

    @Test func showsTheLinkingLine() {
        let body = "intro\n- see [[Target|the target]] for more\n"
        #expect(Links.context(in: body, linkingTo: "target") == "see the target for more")
        #expect(Links.context(in: "[note](ivy://note/target01) here", linkingTo: "", noteID: "target01") == "note here")
    }

    @Test func countsWords() {
        #expect(WordCount.count("你好 world") == 3)
        #expect(WordCount.count("# Title\n\n**bold** and [link](https://x.y)\n```\ncode here\n```\n![img](ivy://res/abcdefgh)") == 4)
        #expect(WordCount.count("- [ ] 待办 task") == 3)
    }
}

@Suite struct RemoteAPITests {
    let server = try! ServerAddress(parsing: "https://notes.example.com")
    static let att = #"{"id":"att00000001","name":"a.png","mime":"image/png","kind":"image","size":3,"sha256":"ab","storage":"local","hasThumb":true,"refs":2,"public":true,"seq":4,"createdAt":1,"updatedAt":2}"#

    @Test func uploadsMultipart() async throws {
        let t = StubTransport(["POST /api/v1/attachments": .json(200, #"{"attachment":\#(Self.att),"duplicate":true}"#)])
        let api = APIClient(server: server, token: "tok", transport: t)
        let r = try await api.upload(Data("png".utf8), name: "a \"b\".png", mime: "image/png")
        #expect(r.duplicate && r.attachment.refs == 2 && r.attachment.public)
        // Tries direct upload-intent first, then falls back cleanly to multipart on 404.
        #expect(t.sent.map { $0.url?.path() } == ["/api/v1/attachments/upload-intent", "/api/v1/attachments"])
        let req = try #require(t.sent.last)
        let type = try #require(req.value(forHTTPHeaderField: "Content-Type"))
        #expect(type.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: req.httpBody!, as: UTF8.self)
        #expect(body.contains(#"Content-Disposition: form-data; name="file"; filename="a %22b%22.png""#))
        #expect(body.contains("Content-Type: image/png\r\n\r\npng\r\n"))
        #expect(body.hasSuffix("--\r\n"))
    }

    @Test func listsMediaWithFilters() async throws {
        let t = StubTransport(["GET /api/v1/attachments": .json(200, #"{"items":[\#(Self.att)],"counts":{"all":1,"orphaned":0},"policy":{"mode":"local","orphanDays":30,"trashDays":30}}"#)])
        let api = APIClient(server: server, token: "tok", transport: t)
        let list = try await api.media(.orphaned, query: "a+b c")
        #expect(list.items.count == 1 && list.policy.orphanDays == 30)
        #expect(t.sent[0].url?.query() == "orphaned=1&q=a%2Bb%20c")
    }

    @Test func setsAShare() async throws {
        let t = StubTransport([
            "PUT /api/v1/notes/n0000001/share": .json(200, #"{"id":"s1","noteId":"n0000001","enabled":true,"expiresAt":0,"views":3,"hasPassword":true,"password":"abcdefgh","noteTitle":"T","expired":false}"#),
            "GET /api/v1/notes/n0000002/share": .json(200, "null"),
        ])
        let api = APIClient(server: server, token: "tok", transport: t)
        let s = try await api.setShare("n0000001", enabled: true, expiresAt: 0)
        #expect(s.isLive && s.password == "abcdefgh" && s.views == 3)
        let body = try JSONSerialization.jsonObject(with: t.sent[0].httpBody!) as! [String: Any]
        #expect(body["password"] == nil) // kept as it is
        #expect(api.shareURL(s).absoluteString == "https://notes.example.com/s/s1")
        #expect(try await api.share("n0000002") == nil)
        #expect(Share.validPassword("123456") && !Share.validPassword("12345"))
        #expect(Share.generatePassword().count == 8)
    }

    @Test func readsHistory() async throws {
        let t = StubTransport([
            "GET /api/v1/notes/n0000001/history": .json(200, #"[{"rev":3,"title":"T","device":"ios-1","size":10,"createdAt":5},{"rev":2,"title":"T","size":4,"createdAt":4}]"#),
            "GET /api/v1/notes/n0000001/history/2": .json(200, #"{"rev":2,"title":"T","body":"old","size":4,"createdAt":4}"#),
        ])
        let api = APIClient(server: server, token: "tok", transport: t)
        let list = try await api.history("n0000001")
        #expect(list.map(\.rev) == [3, 2] && list[1].device.isEmpty)
        #expect(try await api.revision("n0000001", 2).body == "old")
    }
}

@Suite struct MigratorFilesTests {
    let server = try! ServerAddress(parsing: "https://web.ivynote.net")

    @Test func uploadsTheLibrarysFilesFirst() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ivy-mf-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("png".utf8).write(to: dir.appending(path: "local-aaaaaaaa"))
        let up = PendingUpload(id: "local-aaaaaaaa", name: "a.png", mime: "image/png", file: "local-aaaaaaaa", size: 3, createdAt: 1)
        let missing = PendingUpload(id: "local-bbbbbbbb", name: "gone.png", mime: "image/png", file: "local-bbbbbbbb", size: 3, createdAt: 2)
        let t = StubTransport([
            "GET /api/v1/sync/pull": .json(200, #"{"seq":0}"#),
            "POST /api/v1/attachments": .json(200, #"{"attachment":\#(RemoteAPITests.att),"duplicate":false}"#),
            "POST /api/v1/sync/push": .json(200, #"{"seq":1,"results":[{"type":"note","id":"n1","ok":true}]}"#),
        ])
        let content = LibraryMigrator.Content(folders: [], tags: [],
                                              notes: [Note(id: "n1", title: "T", body: "![a.png](ivy://res/local-aaaaaaaa)", createdAt: 1, updatedAt: 1)],
                                              uploads: [up, missing], filesDir: dir)
        let result = try await LibraryMigrator(api: APIClient(server: server, token: "tok", transport: t), device: "ios-test").run(content)
        #expect(result.files == 1)
        #expect(result.skippedFiles.count == 1)
        let push = try #require(t.sent.first(where: { $0.url!.path() == "/api/v1/sync/push" }))
        struct Body: Decodable { var changes: [Change] }
        let change = try JSONDecoder().decode(Body.self, from: push.httpBody!).changes[0]
        #expect(change.fields?["body"] == .string("![a.png](ivy://res/att00000001)"))
    }
}
