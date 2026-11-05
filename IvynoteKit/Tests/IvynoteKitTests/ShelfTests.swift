import Testing
@testable import IvynoteKit

@Suite struct ShelfTests {
    func note(_ id: String, _ title: String, folder: String = "", pinned: Bool = false, updated: Millis = 1, trashed: Millis = 0, tags: [String] = []) -> Note {
        Note(id: id, folderId: folder, title: title, tags: tags, pinned: pinned, trashedAt: trashed, createdAt: updated, updatedAt: updated)
    }
    func folder(_ id: String, _ name: String, parent: String = "", sort: Double = 0) -> Folder {
        Folder(id: id, parentId: parent, name: name, sort: sort, createdAt: 1, updatedAt: 1)
    }
    func keys(_ rows: [Shelf.Row]) -> [String] { rows.map(\.key) }

    let folders = [Folder(id: "fwork", name: "Work", sort: 1, createdAt: 1, updatedAt: 1),
                   Folder(id: "fsub", parentId: "fwork", name: "Sub", sort: 1, createdAt: 1, updatedAt: 1),
                   Folder(id: "fhome", name: "Home", sort: 2, createdAt: 1, updatedAt: 1)]

    @Test func rootNotesSitBelowNotebooks() {
        let notes = [note("n1", "Root", updated: 5), note("n2", "In work", folder: "fwork")]
        let rows = Shelf.build(folders: folders, notes: notes, tags: [], expanded: [], sortBy: .updated)
        #expect(keys(rows) == ["h:notes", "fwork", "fhome", "/n1", "v:trash"])
        #expect(rows[1].count == 1 && rows[1].expandable && !rows[1].open)
        #expect(rows[2].count == 0 && !rows[2].expandable)
    }

    @Test func openNotebooksListSubNotebooksBeforeNotes() {
        let notes = [note("n2", "In work", folder: "fwork"), note("n3", "Deep", folder: "fsub")]
        let rows = Shelf.build(folders: folders, notes: notes, tags: [], expanded: ["fwork", "fsub"], sortBy: .updated)
        #expect(keys(rows) == ["h:notes", "fwork", "fsub", "fsub/n3", "fwork/n2", "fhome", "v:trash"])
        #expect(rows.first { $0.key == "fwork" }?.count == 2) // includes the sub-notebook
        #expect(rows.first { $0.key == "fsub/n3" }?.depth == 2)
        #expect(rows.first { $0.key == "fwork/n2" }?.folderID == "fwork")
    }

    @Test func orphansFallToTheTop() {
        let notes = [note("n1", "Lost", folder: "gone")]
        let fs = [folder("fa", "A", parent: "gone")]
        let rows = Shelf.build(folders: fs, notes: notes, tags: [], expanded: [], sortBy: .updated)
        #expect(keys(rows) == ["h:notes", "fa", "/n1", "v:trash"])
        #expect(rows[1].depth == 0)
    }

    @Test func pinnedTagsAndTrashGroups() {
        let tag = Tag(id: "t1", name: "idea", createdAt: 1, updatedAt: 1)
        let notes = [note("n1", "P", pinned: true, tags: ["t1"]), note("n2", "T", trashed: 9)]
        let shut = Shelf.build(folders: [], notes: notes, tags: [tag], expanded: [], sortBy: .updated)
        #expect(keys(shut) == ["v:pinned", "h:notes", "h:create", "/n1", "v:tags", "v:trash"])
        #expect(shut.last?.count == 1)
        let open = Shelf.build(folders: [], notes: notes, tags: [tag], expanded: ["v:pinned", "v:tags", "t:t1", "v:trash"], sortBy: .updated)
        #expect(keys(open) == ["v:pinned", "v:pinned/n1", "h:notes", "h:create", "/n1", "v:tags", "t:t1", "t:t1/n1", "v:trash", "v:trash/n2"])
    }

    @Test func longBranchesArePaged() {
        let notes = (0..<130).map { note("n\($0)", "N\($0)", updated: Millis($0)) }
        let rows = Shelf.build(folders: [], notes: notes, tags: [], expanded: [], sortBy: .updated)
        #expect(rows.filter { $0.kind == .note }.count == 100)
        #expect(rows.first { $0.kind == .more }?.count == 30)
        let more = Shelf.build(folders: [], notes: notes, tags: [], expanded: [], sortBy: .updated, limits: ["": 200])
        #expect(more.filter { $0.kind == .note }.count == 130)
    }

    @Test func sorting() {
        let notes = [note("a", "乙", updated: 1), note("b", "", updated: 3), note("c", "甲", updated: 2), note("d", "丙", pinned: true)]
        #expect(Shelf.sortNotes(notes, by: .updated).map(\.id) == ["d", "b", "c", "a"])
        #expect(Shelf.sortNotes(notes, by: .title).map(\.title) == ["丙", "甲", "乙", ""])
    }

    @Test func revealAndHome() {
        let map = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        let deep = note("n3", "Deep", folder: "fsub")
        #expect(Shelf.revealKeys(for: deep, folders: map) == ["fwork", "fsub"])
        #expect(Shelf.homeKey(for: deep, folders: map) == "fsub/n3")
        #expect(Shelf.homeKey(for: note("n1", "R"), folders: map) == "/n1")
        #expect(Shelf.revealKeys(for: note("n2", "T", trashed: 1), folders: map) == ["v:trash"])
    }
}
