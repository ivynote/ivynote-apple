import Foundation
import Testing
@testable import IvynoteKit

@MainActor
@Suite struct UploadQueueTests {
    func engine(_ fake: FakeSync?) throws -> SyncEngine {
        SyncEngine(store: try LocalStore(url: nil), transport: fake, device: "test-1",
                   debounce: .seconds(3600), persistDelay: .seconds(3600), now: { 1_800_000_000_000 })
    }

    @Test func uploadsAtOnceWhenOnline() async throws {
        let fake = FakeSync()
        let e = try engine(fake)
        let f = try await e.addFile(Data("png".utf8), name: "photo.png", mime: "image/png")
        #expect(!f.local)
        #expect(f.markdown == "![photo.png](ivy://res/\(f.id))")
        #expect(e.attachments[f.id]?.kind == "image")
        #expect(e.uploads.isEmpty)
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

        fake.uploadHandler = { data, name, mime in
            Attachment(id: "att00000001", name: name, mime: mime, size: Int64(data.count), createdAt: 1, updatedAt: 1)
        }
        let recoveryStart = fake.calls.count
        await e.sync()
        #expect(e.uploads.isEmpty && e.state.uploads == 0)
        #expect(e.notes[note.id]?.body == "see [report.pdf](ivy://res/att00000001)\n")
        #expect(!FileManager.default.fileExists(atPath: copy.url.path))
        // Uploaded before the push, so the body went out with the server's id.
        #expect(Array(fake.calls[recoveryStart...]) == ["upload:report.pdf", "push:1", "pull:1"])
        let pushed = try #require(fake.pushed.last?.first)
        #expect(pushed.fields?["body"] == .string("see [report.pdf](ivy://res/att00000001)\n"))
    }

    @Test func aRefusedFileStaysQueuedAndSyncGoesOn() async throws {
        let fake = FakeSync()
        fake.uploadHandler = { _, _, _ in throw APIError.unreachable("offline") }
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
        fake.uploadHandler = { _, _, _ in throw APIError.unreachable("offline") }
        let e = try engine(fake)
        _ = try await e.addFile(Data(count: 3), name: "a.png", mime: "image/png")
        fake.uploadHandler = { _, _, _ in throw APIError.server(status: 503, message: "") }
        await e.sync()
        #expect(e.state.status == .offline)
        #expect(e.uploads.count == 1)
        #expect(fake.pushed.isEmpty)
    }

    @Test func otherErrorsAreNotQueued() async throws {
        let fake = FakeSync()
        fake.uploadHandler = { _, _, _ in throw APIError.server(status: 413, message: "file too large") }
        let e = try engine(fake)
        await #expect(throws: APIError.server(status: 413, message: "file too large")) {
            try await e.addFile(Data(count: 3), name: "a.png", mime: "image/png")
        }
        #expect(e.uploads.isEmpty)
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
        fake.uploadHandler = { _, _, _ in throw APIError.unreachable("offline") }
        let id: String
        do {
            let e = SyncEngine(store: try LocalStore(url: url), transport: fake, device: "d", debounce: .seconds(3600))
            id = try await e.addFile(Data("x".utf8), name: "a.png", mime: "image/png").id
            e.stop()
        }
        let e = SyncEngine(store: try LocalStore(url: url), transport: fake, device: "d", debounce: .seconds(3600))
        try e.load()
        #expect(e.uploads[id]?.name == "a.png")
        #expect(e.uploadFile(id).map { FileManager.default.fileExists(atPath: $0.url.path) } == true)
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
        let req = try #require(t.sent.first)
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
