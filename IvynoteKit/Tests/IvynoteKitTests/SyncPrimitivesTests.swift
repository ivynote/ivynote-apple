import Foundation
import Testing
@testable import IvynoteKit

@Suite struct HLCTests {
    @Test func formatsLikeTheServer() {
        #expect(HLC.format(wall: 1793503505537, counter: 0, node: "desk-1") == "1793503505537-0000-desk-1")
        #expect(HLC.format(wall: 5, counter: 255, node: "n") == "0000000000005-00ff-n")
    }

    @Test func parsesNodesWithDashes() throws {
        let p = try #require(HLC.parse("1793503505537-00ff-ios-a-b"))
        #expect(p.wall == 1793503505537)
        #expect(p.counter == 255)
        #expect(p.node == "ios-a-b")
        #expect(HLC.parse("garbage") == nil)
    }

    @Test func ticksMonotonically() {
        var c = HLC(node: "n")
        let a = c.tick(now: 1000), b = c.tick(now: 1000), d = c.tick(now: 999)
        #expect(a < b && b < d)
        #expect(c.tick(now: 2000) == "0000000002000-0000-n")
    }

    @Test func observeMovesForward() {
        var c = HLC(node: "n")
        c.observe("0000000005000-0003-x")
        #expect(c.tick(now: 1000) == "0000000005000-0004-n")
    }
}

@Suite struct SSEParseTests {
    @Test func readsSeqEvents() {
        var event = ""
        let lines = ["retry: 3000", "event: seq", "data: 0", "", ": ping", "event: seq", "data: 12", ""]
        let seqs = lines.compactMap { SyncEvents.parse($0, event: &event) }
        #expect(seqs == [0, 12])
    }

    @Test func worksWithoutBlankLines() {
        // AsyncLineSequence may drop empty lines; events still parse.
        var event = ""
        let seqs = ["event: seq", "data: 3", "event: seq", "data: 4"].compactMap { SyncEvents.parse($0, event: &event) }
        #expect(seqs == [3, 4])
    }

    @Test func ignoresOtherEvents() {
        var event = ""
        #expect(["event: other", "data: 9"].compactMap { SyncEvents.parse($0, event: &event) }.isEmpty)
    }
}

@Suite struct LocalStoreTests {
    @Test func roundTripsDocumentsAndMeta() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ivy-\(UUID())/library.sqlite")
        defer { LocalStore.remove(at: url) }
        do {
            let s = try LocalStore(url: url)
            let n = Note(id: "n1234567", title: "T", body: "B", createdAt: 1, updatedAt: 2)
            try s.put(.notes, [(n.id, n)])
            try s.setMeta("cursor", Int64(42))
        }
        let s = try LocalStore(url: url)
        let notes: [Note] = try s.all(.notes)
        #expect(notes.map(\.title) == ["T"])
        #expect(s.meta("cursor", as: Int64.self) == 42)
        try s.delete(.notes, ["n1234567"])
        #expect(try s.all(.notes, as: Note.self).isEmpty)
    }

    @Test func rollsBackFailedTransactions() throws {
        let s = try LocalStore(url: nil)
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try s.transaction {
                try s.put(.tags, [("t1234567", IvynoteKit.Tag(id: "t1234567", name: "x", createdAt: 0, updatedAt: 0))])
                throw Boom()
            }
        }
        #expect(try s.all(.tags, as: IvynoteKit.Tag.self).isEmpty)
    }

    @Test func decodesServerNotesWithMissingZeroValues() throws {
        let json = #"{"id":"n1234567","title":"Hi","rev":2,"seq":5,"createdAt":1,"updatedAt":2}"#
        let n = try JSONDecoder().decode(Note.self, from: Data(json.utf8))
        #expect(n.body == "" && n.tags.isEmpty && !n.pinned && n.trashedAt == 0 && !n.deleted)
    }

    @Test func accountsGetSeparateLibraries() throws {
        let server = try ServerAddress(parsing: "notes.example.com")
        let a = StoredAccount(server: server, token: "", user: User(id: "u1", username: "a"))
        let b = StoredAccount(server: server, token: "", user: User(id: "u2", username: "b"))
        #expect(LocalStore.url(for: a) != LocalStore.url(for: b))
        #expect(LocalStore.url(for: a) == LocalStore.url(for: a))
    }
}
