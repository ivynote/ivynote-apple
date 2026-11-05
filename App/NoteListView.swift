import IvynoteKit
import SwiftUI

struct NoteListView: View {
    @Environment(SyncEngine.self) private var engine
    let scope: SidebarItem
    @Binding var selection: String?

    @State private var query = ""
    @State private var confirmEmpty = false

    private var isTrash: Bool { scope == .trash }

    private var title: String {
        switch scope {
        case .all: "全部笔记"
        case .trash: "回收站"
        case .folder(let id): engine.folders[id]?.name ?? "笔记本"
        case .tag(let id): "#" + (engine.tags[id]?.name ?? "")
        }
    }

    private var notes: [Note] {
        var list: [Note] = switch scope {
        case .all: engine.liveNotes
        case .trash: engine.trashedNotes
        case .folder(let id): engine.liveNotes.filter { $0.folderId == id }
        case .tag(let id): engine.liveNotes.filter { $0.tags.contains(id) }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.body.localizedCaseInsensitiveContains(q) }
        }
        // Pinned first, then most recently updated (guide 3.3).
        return list.sorted {
            if !isTrash && $0.pinned != $1.pinned { return $0.pinned }
            return isTrash ? $0.trashedAt > $1.trashedAt : $0.updatedAt > $1.updatedAt
        }
    }

    var body: some View {
        let notes = notes
        List(selection: $selection) {
            ForEach(notes) { n in
                NoteRow(note: n)
                    .tag(n.id)
                    .swipeActions(edge: .trailing) { trailingActions(n) }
                    .swipeActions(edge: .leading) {
                        if !isTrash {
                            Button(n.pinned ? "取消置顶" : "置顶", systemImage: n.pinned ? "pin.slash" : "pin") {
                                engine.updateNote(n.id, .init(pinned: !n.pinned))
                            }
                            .tint(.orange)
                        }
                    }
                    .contextMenu { menu(n) }
            }
        }
        .overlay {
            if notes.isEmpty {
                if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if engine.state.initial {
                    ContentUnavailableView { Label("正在下载笔记…", systemImage: "arrow.down.circle") }
                } else {
                    ContentUnavailableView(isTrash ? "回收站是空的" : "没有笔记", systemImage: isTrash ? "trash" : "note.text")
                }
            }
        }
        .searchable(text: $query, prompt: "搜索笔记")
        .navigationTitle(title)
        .toolbar {
            if isTrash {
                if !notes.isEmpty {
                    Button("清空回收站", role: .destructive) { confirmEmpty = true }
                }
            } else {
                Button("新建笔记", systemImage: "square.and.pencil", action: newNote)
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .confirmationDialog("永久删除回收站中的全部笔记？", isPresented: $confirmEmpty) {
            Button("清空回收站", role: .destructive) {
                selection = nil
                engine.emptyTrash()
            }
        } message: {
            Text("此操作无法撤销。")
        }
    }

    @ViewBuilder private func trailingActions(_ n: Note) -> some View {
        if isTrash {
            Button("永久删除", systemImage: "trash.slash", role: .destructive) { deleteForever(n) }
            Button("恢复", systemImage: "arrow.uturn.backward") { engine.updateNote(n.id, .init(trashed: false)) }
                .tint(.green)
        } else {
            Button("移到回收站", systemImage: "trash", role: .destructive) { trash(n) }
        }
    }

    @ViewBuilder private func menu(_ n: Note) -> some View {
        if isTrash {
            Button("恢复", systemImage: "arrow.uturn.backward") { engine.updateNote(n.id, .init(trashed: false)) }
            Button("永久删除", systemImage: "trash.slash", role: .destructive) { deleteForever(n) }
        } else {
            Button(n.pinned ? "取消置顶" : "置顶", systemImage: n.pinned ? "pin.slash" : "pin") {
                engine.updateNote(n.id, .init(pinned: !n.pinned))
            }
            MoveToFolderMenu(note: n)
            Button("移到回收站", systemImage: "trash", role: .destructive) { trash(n) }
        }
    }

    private func newNote() {
        let folder: String = if case .folder(let id) = scope { id } else { "" }
        let tags: [String] = if case .tag(let id) = scope { [id] } else { [] }
        query = ""
        selection = engine.createNote(folderId: folder, tags: tags).id
    }

    private func trash(_ n: Note) {
        if selection == n.id { selection = nil }
        engine.updateNote(n.id, .init(trashed: true))
    }

    private func deleteForever(_ n: Note) {
        if selection == n.id { selection = nil }
        engine.deleteNote(n.id)
    }
}

struct NoteRow: View {
    @Environment(SyncEngine.self) private var engine
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if note.pinned && !note.isTrashed {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                }
                Text(displayTitle(note))
                    .font(.headline)
                    .foregroundStyle(note.title.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
            }
            let excerpt = Self.excerpt(note.body)
            if !excerpt.isEmpty {
                Text(excerpt).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(Date(timeIntervalSince1970: Double(note.updatedAt) / 1000), format: .dateTime.month().day().hour().minute())
                if !note.folderId.isEmpty, let f = engine.folders[note.folderId] {
                    Label(f.name, systemImage: "folder").labelStyle(.titleAndIcon)
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
