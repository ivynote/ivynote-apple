import IvynoteKit
import SwiftUI

/// The bookshelf and the paper (guide 11.1): the shelf tree on the left, the
/// open note on the right; on iPhone one at a time.
struct LibraryView: View {
    @Environment(SyncEngine.self) private var engine
    @Environment(EditorHost.self) private var editor
    @Environment(Library.self) private var library

    /// The selected row's key; a note can show in several places (pinned,
    /// tags, its notebook), and each row is selected on its own.
    @State private var selection: String?
    @State private var expanded: Set<String> = []
    @State private var showAccount = false

    private var selectedNote: String? { selection.flatMap(noteID(fromKey:)) }

    var body: some View {
        NavigationSplitView {
            ShelfView(selection: $selection, expanded: $expanded, showAccount: $showAccount, reveal: reveal)
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 240, ideal: 296, max: 420)
                #endif
        } detail: {
            if let id = selectedNote, engine.notes[id] != nil {
                NoteEditorView(noteID: id).id(id)
            } else {
                ContentUnavailableView("未选择笔记", systemImage: "note.text")
            }
        }
        .sheet(isPresented: $showAccount) { AccountView() }
        .alert("内容冲突", isPresented: Binding(get: { engine.conflict != nil }, set: { if !$0 { engine.conflict = nil } }), presenting: engine.conflict) { c in
            Button("打开副本") {
                reveal(c.copyID)
                engine.conflict = nil
            }
            Button("好", role: .cancel) { engine.conflict = nil }
        } message: { c in
            Text("「\(engine.notes[c.noteID].map(displayTitle) ?? "笔记")」在其他设备上也改动了同一处。服务器保留了它的版本，你的修改已另存为冲突副本。")
        }
        .onAppear {
            expanded = ShelfState.load(for: library.account)
            editor.onOpenNote = { id, title in openLink(id: id, title: title) }
            #if DEBUG
            // `-ivyOpenNote <title>` opens a note at launch, for checking
            // rendering without tapping through the tree.
            if let title = UserDefaults.standard.string(forKey: "ivyOpenNote"),
               let n = engine.liveNotes.first(where: { $0.title == title }) {
                reveal(n.id)
            }
            #endif
        }
        .onChange(of: expanded) { _, keys in ShelfState.save(keys, for: library.account) }
    }

    /// Opens a note where it lives in the tree, expanding the path to it.
    func reveal(_ id: String) {
        guard let note = engine.notes[id] else { return }
        expanded.formUnion(Shelf.revealKeys(for: note, folders: engine.folders))
        selection = Shelf.homeKey(for: note, folders: engine.folders)
    }

    /// A followed `[[wiki link]]`. A missing note is created, like a wiki,
    /// in the notebook of the note the link is in (guide 3.2).
    func openLink(id: String, title: String) {
        if !id.isEmpty, engine.notes[id] != nil {
            reveal(id)
            return
        }
        let name = title.split(separator: "#").first.map(String.init)?.split(separator: "|").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !name.isEmpty else { return }
        let folder = selectedNote.flatMap { engine.notes[$0]?.folderId } ?? ""
        reveal(engine.createNote(title: name, folderId: folder).id)
    }
}

/// Row keys are `parent/noteID` for notes (see `Shelf.build`).
func noteID(fromKey key: String) -> String? {
    guard let slash = key.lastIndex(of: "/") else { return nil }
    let id = String(key[key.index(after: slash)...])
    return id == "more" || id.isEmpty ? nil : id
}

func displayTitle(_ n: Note) -> String {
    n.title.trimmingCharacters(in: .whitespaces).isEmpty ? "无标题" : n.title
}

/// Which branches are open, kept on this device per account (guide 11.2).
enum ShelfState {
    private static func key(_ account: StoredAccount) -> String { "ivy.shelf.expanded.\(account.server)|\(account.user.id)" }

    static func load(for account: StoredAccount) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key(account)) ?? [])
    }

    static func save(_ keys: Set<String>, for account: StoredAccount) {
        UserDefaults.standard.set(Array(keys), forKey: key(account))
    }
}

// MARK: Shelf

struct ShelfView: View {
    @Environment(SyncEngine.self) private var engine
    @Binding var selection: String?
    @Binding var expanded: Set<String>
    @Binding var showAccount: Bool
    let reveal: (String) -> Void

    @AppStorage("ivy.shelf.sort") private var sortBy: Shelf.SortBy = .updated
    @State private var limits: [String: Int] = [:]
    @State private var query = ""
    @State private var newFolderParent: String?
    @State private var renaming: Folder?
    @State private var deleting: Folder?
    @State private var confirmEmpty = false
    @State private var nameDraft = ""

    var body: some View {
        List(selection: $selection) {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                ForEach(rows) { row in
                    rowView(row)
                        .tag(row.key)
                        .selectionDisabled(row.kind != .note)
                        .contextMenu { menu(for: row) }
                        .swipeActions(edge: .trailing) { swipes(for: row) }
                        .listRowInsets(EdgeInsets(top: row.gap ? 14 : 0, leading: 10, bottom: 0, trailing: 12))
                        .listRowSeparator(.hidden)
                }
            } else {
                searchResults
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 34)
        .searchable(text: $query, placement: .sidebar, prompt: "搜索笔记")
        .navigationTitle("常青笔记")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("账户", systemImage: "person.crop.circle") { showAccount = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("新建笔记", systemImage: "square.and.pencil") { newNote(in: "") }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .safeAreaInset(edge: .bottom) {
            SyncStatusView()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
        .refreshable { await engine.sync() }
        .alert("新建笔记本", isPresented: Binding(get: { newFolderParent != nil }, set: { if !$0 { newFolderParent = nil } })) {
            TextField("名称", text: $nameDraft)
            Button("取消", role: .cancel) {}
            Button("创建") {
                let name = nameDraft.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, let parent = newFolderParent {
                    engine.createFolder(name: String(name.prefix(100)), parentId: parent)
                    if !parent.isEmpty { expanded.insert(parent) }
                }
            }
        }
        .alert("重命名笔记本", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $nameDraft)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let name = nameDraft.trimmingCharacters(in: .whitespaces)
                if let f = renaming, !name.isEmpty { engine.renameFolder(f.id, to: String(name.prefix(100))) }
            }
        }
        .confirmationDialog("删除笔记本？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { f in
            Button("删除「\(f.name)」", role: .destructive) { engine.deleteFolder(f.id) }
        } message: { _ in
            Text("子笔记本会一起删除，其中的笔记移到回收站。")
        }
        .confirmationDialog("永久删除回收站中的全部笔记？", isPresented: $confirmEmpty) {
            Button("清空回收站", role: .destructive) {
                if let id = selection.flatMap(noteID(fromKey:)), engine.notes[id]?.isTrashed == true { selection = nil }
                engine.emptyTrash()
            }
        } message: {
            Text("此操作无法撤销。")
        }
    }

    private var rows: [Shelf.Row] {
        Shelf.build(folders: Array(engine.folders.values), notes: Array(engine.notes.values), tags: Array(engine.tags.values),
                    expanded: expanded, sortBy: sortBy, limits: limits)
    }

    @ViewBuilder private var searchResults: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let hits = Shelf.sortNotes(engine.liveNotes.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.body.localizedCaseInsensitiveContains(q)
        }, by: sortBy)
        if hits.isEmpty {
            ContentUnavailableView.search(text: q)
        } else {
            ForEach(hits.prefix(200)) { n in
                NoteRow(note: n).tag("s/\(n.id)" as String?)
            }
        }
    }

    /// Notes are selected by the list itself (on iPhone that opens the note);
    /// every other row is a button that opens or closes its branch.
    @ViewBuilder private func rowView(_ row: Shelf.Row) -> some View {
        let label = ShelfRowView(row: row, sortBy: $sortBy, onNewFolder: { startNewFolder(parent: "") }, onNewNote: newNote)
        if row.kind == .note || row.kind == .heading {
            label
        } else {
            Button { tap(row) } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        }
    }

    private func tap(_ row: Shelf.Row) {
        switch row.kind {
        case .group, .folder, .tag:
            guard row.expandable else { return }
            withAnimation(.snappy(duration: 0.2)) {
                if expanded.contains(row.key) { expanded.remove(row.key) } else { expanded.insert(row.key) }
            }
        case .more:
            limits[row.parent] = (limits[row.parent] ?? Shelf.page) + Shelf.page
        case .create:
            startNewFolder(parent: "")
        case .note:
            selection = row.key
        case .heading:
            break
        }
    }

    @ViewBuilder private func menu(for row: Shelf.Row) -> some View {
        switch row.kind {
        case .folder:
            if let f = row.folder {
                Button("新建笔记", systemImage: "square.and.pencil") { newNote(in: f.id) }
                Button("新建子笔记本", systemImage: "folder.badge.plus") { startNewFolder(parent: f.id) }
                Button("重命名", systemImage: "pencil") { nameDraft = f.name; renaming = f }
                Button("删除", systemImage: "trash", role: .destructive) { deleting = f }
            }
        case .note:
            if let n = row.note { NoteMenu(note: n, selection: $selection) }
        case .group where row.key == Shelf.trashKey && row.count > 0:
            Button("清空回收站", systemImage: "trash.slash", role: .destructive) { confirmEmpty = true }
        case .heading:
            Button("新建笔记", systemImage: "square.and.pencil") { newNote(in: "") }
            Button("新建笔记本", systemImage: "folder.badge.plus") { startNewFolder(parent: "") }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func swipes(for row: Shelf.Row) -> some View {
        if let n = row.note {
            if n.isTrashed {
                Button("永久删除", systemImage: "trash.slash", role: .destructive) {
                    if selection == row.key { selection = nil }
                    engine.deleteNote(n.id)
                }
                Button("恢复", systemImage: "arrow.uturn.backward") { engine.updateNote(n.id, .init(trashed: false)) }
                    .tint(.green)
            } else {
                Button("移到回收站", systemImage: "trash", role: .destructive) {
                    if selection == row.key { selection = nil }
                    engine.updateNote(n.id, .init(trashed: true))
                }
                Button(n.pinned ? "取消置顶" : "置顶", systemImage: n.pinned ? "pin.slash" : "pin") {
                    engine.updateNote(n.id, .init(pinned: !n.pinned))
                }
                .tint(.orange)
            }
        }
    }

    private func newNote(in folder: String) {
        query = ""
        if !folder.isEmpty { expanded.insert(folder) }
        reveal(engine.createNote(folderId: folder).id)
    }

    private func startNewFolder(parent: String) {
        nameDraft = ""
        newFolderParent = parent
    }
}

struct ShelfRowView: View {
    let row: Shelf.Row
    @Binding var sortBy: Shelf.SortBy
    let onNewFolder: () -> Void
    let onNewNote: (String) -> Void

    var body: some View {
        switch row.kind {
        case .heading:
            HStack {
                Text(row.label).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Picker("排序", selection: $sortBy) {
                        ForEach(Shelf.SortBy.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Divider()
                    Button("新建笔记", systemImage: "square.and.pencil") { onNewNote("") }
                    Button("新建笔记本", systemImage: "folder.badge.plus", action: onNewFolder)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 28, height: 24)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        case .create:
            Label("新建笔记本", systemImage: "plus").foregroundStyle(.secondary)
        case .more:
            HStack(spacing: 6) {
                indent
                Text("再显示 \(min(row.count, Shelf.page)) 篇（共 \(row.count) 篇未显示）")
                    .font(.footnote).foregroundStyle(.tint)
            }
        default:
            HStack(spacing: 6) {
                indent
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(row.open ? 90 : 0))
                    .frame(width: 12)
                    .opacity(row.expandable ? 1 : 0)
                Image(systemName: icon)
                    .foregroundStyle(row.kind == .note ? Color.secondary : Color.accentColor)
                    .frame(width: 20)
                Text(title)
                    .lineLimit(1)
                    .foregroundStyle(row.kind == .note && row.label.isEmpty ? .secondary : .primary)
                Spacer(minLength: 4)
                if let n = row.note, n.pinned, !n.isTrashed, row.parent != Shelf.pinnedKey {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                }
                if row.count > 0 {
                    Text("\(row.count)").font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    private var indent: some View {
        Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
    }

    private var title: String {
        switch row.kind {
        case .note: row.label.trimmingCharacters(in: .whitespaces).isEmpty ? "无标题" : row.label
        case .tag: "#" + row.label
        default: row.label
        }
    }

    private var icon: String {
        switch row.kind {
        case .note: "doc.text"
        case .folder: row.open ? "folder.fill" : "folder"
        case .tag: "number"
        case .group:
            switch row.key {
            case Shelf.pinnedKey: "pin"
            case Shelf.tagsKey: "tag"
            default: "trash"
            }
        default: "circle"
        }
    }
}

/// The actions on a note, shared by the tree and the editor's menu.
struct NoteMenu: View {
    @Environment(SyncEngine.self) private var engine
    let note: Note
    @Binding var selection: String?

    var body: some View {
        if note.isTrashed {
            Button("恢复", systemImage: "arrow.uturn.backward") { engine.updateNote(note.id, .init(trashed: false)) }
            Button("永久删除", systemImage: "trash.slash", role: .destructive) {
                clearIfSelected()
                engine.deleteNote(note.id)
            }
        } else {
            Button(note.pinned ? "取消置顶" : "置顶", systemImage: note.pinned ? "pin.slash" : "pin") {
                engine.updateNote(note.id, .init(pinned: !note.pinned))
            }
            MoveToFolderMenu(note: note)
            Button("移到回收站", systemImage: "trash", role: .destructive) {
                clearIfSelected()
                engine.updateNote(note.id, .init(trashed: true))
            }
        }
    }

    private func clearIfSelected() {
        if selection.flatMap(noteID(fromKey:)) == note.id { selection = nil }
    }
}

/// A search hit: title, excerpt, date and notebook.
struct NoteRow: View {
    @Environment(SyncEngine.self) private var engine
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(displayTitle(note))
                .font(.headline)
                .foregroundStyle(note.title.isEmpty ? .secondary : .primary)
                .lineLimit(1)
            let excerpt = Self.excerpt(note.body)
            if !excerpt.isEmpty {
                Text(excerpt).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(Date(timeIntervalSince1970: Double(note.updatedAt) / 1000), format: .dateTime.month().day().hour().minute())
                if let f = engine.folders[note.folderId] {
                    Label(f.name, systemImage: "folder")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    /// The first words of the body without Markdown syntax noise.
    static func excerpt(_ body: String) -> String {
        var out = ""
        for line in body.split(whereSeparator: \.isNewline) {
            var s = line.trimmingCharacters(in: .whitespaces)
            while let c = s.first, "#>-*+`".contains(c) { s.removeFirst() }
            s = s.replacingOccurrences(of: "[ ] ", with: "").replacingOccurrences(of: "[x] ", with: "")
            s = s.trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("```") { continue }
            out += (out.isEmpty ? "" : " ") + s
            if out.count > 140 { break }
        }
        return String(out.prefix(140))
    }
}

struct MoveToFolderMenu: View {
    @Environment(SyncEngine.self) private var engine
    let note: Note

    var body: some View {
        Menu("移动到", systemImage: "folder") {
            option("无笔记本", id: "")
            ForEach(flatFolders(), id: \.folder.id) { item in
                option(String(repeating: "    ", count: item.depth) + item.folder.name, id: item.folder.id)
            }
        }
    }

    private func option(_ name: String, id: String) -> some View {
        Button {
            engine.updateNote(note.id, .init(folderId: id))
        } label: {
            if note.folderId == id { Label(name, systemImage: "checkmark") } else { Text(name) }
        }
    }

    private func flatFolders() -> [(folder: Folder, depth: Int)] {
        let byParent = Dictionary(grouping: engine.folders.values, by: \.parentId)
        var out: [(Folder, Int)] = []
        func walk(_ parent: String, _ depth: Int) {
            guard depth < 64 else { return }
            for f in (byParent[parent] ?? []).sorted(by: { ($0.sort, $0.name) < ($1.sort, $1.name) }) {
                out.append((f, depth))
                walk(f.id, depth + 1)
            }
        }
        walk("", 0)
        return out
    }
}

// MARK: Sync status

struct SyncStatusView: View {
    @Environment(SyncEngine.self) private var engine

    var body: some View {
        let s = engine.state
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                switch s.status {
                case .syncing:
                    ProgressView().controlSize(.mini)
                    Text(s.initial ? "正在下载笔记…" : "同步中…")
                case .offline:
                    Image(systemName: "wifi.slash")
                    Text(s.pending > 0 ? "离线 · \(s.pending) 条待同步" : "离线")
                case .error:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("同步出错").help(s.error ?? "")
                case .idle:
                    if s.pending > 0 {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("\(s.pending) 条待同步")
                    } else if s.lastSyncAt > 0 {
                        Image(systemName: "checkmark.icloud")
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text("已同步 · \(Date(timeIntervalSince1970: Double(s.lastSyncAt) / 1000).formatted(.relative(presentation: .named)))")
                        }
                    } else {
                        Text("尚未同步")
                    }
                }
            }
            if s.blocked > 0 {
                Text("\(s.blocked) 条更改被服务器拒绝").foregroundStyle(.orange)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}
