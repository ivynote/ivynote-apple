import IvynoteKit
import SwiftUI

enum SidebarItem: Hashable {
    case all
    case folder(String)
    case tag(String)
    case trash
}

/// Three columns on iPad and Mac (sidebar, note list, editor); a stack on iPhone.
struct LibraryView: View {
    @Environment(SyncEngine.self) private var engine
    @Environment(EditorHost.self) private var editor
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var sidebar: SidebarItem?
    @State private var selectedNote: String?
    @State private var showAccount = false

    var body: some View {
        @Bindable var engine = engine
        NavigationSplitView {
            SidebarView(selection: $sidebar, showAccount: $showAccount)
        } content: {
            if let sidebar {
                NoteListView(scope: sidebar, selection: $selectedNote)
            } else {
                ContentUnavailableView("选择一个笔记本", systemImage: "books.vertical")
            }
        } detail: {
            if let selectedNote, engine.notes[selectedNote] != nil {
                NoteEditorView(noteID: selectedNote)
                    .id(selectedNote)
            } else {
                ContentUnavailableView("未选择笔记", systemImage: "note.text")
            }
        }
        .onAppear {
            if sidebar == nil && sizeClass != .compact { sidebar = .all }
            editor.onOpenNote = { id, title in openLink(id: id, title: title) }
            #if DEBUG
            // `-ivyOpenNote <title>` opens a note at launch, for checking
            // rendering without tapping through the list.
            if let title = UserDefaults.standard.string(forKey: "ivyOpenNote"),
               let n = engine.liveNotes.first(where: { $0.title == title }) {
                sidebar = .all
                // After onChange(of: sidebar) has cleared the selection.
                Task { @MainActor in selectedNote = n.id }
            }
            #endif
        }
        .onChange(of: sidebar) { selectedNote = nil }
        .sheet(isPresented: $showAccount) { AccountView() }
        .alert("内容冲突", isPresented: Binding(get: { engine.conflict != nil }, set: { if !$0 { engine.conflict = nil } }), presenting: engine.conflict) { c in
            Button("打开副本") {
                sidebar = .all
                selectedNote = c.copyID
                engine.conflict = nil
            }
            Button("好", role: .cancel) { engine.conflict = nil }
        } message: { c in
            Text("「\(engine.notes[c.noteID].map(displayTitle) ?? "笔记")」在其他设备上也改动了同一处。服务器保留了它的版本，你的修改已另存为冲突副本。")
        }
    }
}

extension LibraryView {
    /// A followed `[[wiki link]]`. A missing note is created, like a wiki,
    /// in the notebook of the note the link is in (guide 3.2).
    func openLink(id: String, title: String) {
        if !id.isEmpty, engine.notes[id] != nil {
            selectedNote = id
            return
        }
        let name = title.split(separator: "#").first.map(String.init)?.split(separator: "|").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !name.isEmpty else { return }
        let folder = selectedNote.flatMap { engine.notes[$0]?.folderId } ?? ""
        selectedNote = engine.createNote(title: name, folderId: folder).id
    }
}

func displayTitle(_ n: Note) -> String {
    n.title.trimmingCharacters(in: .whitespaces).isEmpty ? "无标题" : n.title
}

// MARK: Sidebar

struct FolderNode: Identifiable {
    let folder: Folder
    var children: [FolderNode]?
    var id: String { folder.id }
}

struct SidebarView: View {
    @Environment(SyncEngine.self) private var engine
    @Binding var selection: SidebarItem?
    @Binding var showAccount: Bool

    @State private var newFolderParent: String?
    @State private var renaming: Folder?
    @State private var deleting: Folder?
    @State private var nameDraft = ""

    var body: some View {
        List(selection: $selection) {
            Section {
                row("全部笔记", "note.text", count: engine.liveNotes.count).tag(SidebarItem.all)
            }
            Section("笔记本") {
                OutlineGroup(folderTree(), children: \.children) { node in
                    row(node.folder.name, "folder", count: count(in: node.id))
                        .tag(SidebarItem.folder(node.id))
                        .contextMenu {
                            Button("新建子笔记本", systemImage: "folder.badge.plus") { startNewFolder(parent: node.id) }
                            Button("重命名", systemImage: "pencil") { nameDraft = node.folder.name; renaming = node.folder }
                            Button("删除", systemImage: "trash", role: .destructive) { deleting = node.folder }
                        }
                }
            }
            let tags = engine.tags.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if !tags.isEmpty {
                Section("标签") {
                    ForEach(tags) { t in
                        row("#" + t.name, "number", count: engine.liveNotes.filter { $0.tags.contains(t.id) }.count)
                            .tag(SidebarItem.tag(t.id))
                    }
                }
            }
            Section {
                row("回收站", "trash", count: engine.trashedNotes.count).tag(SidebarItem.trash)
            }
        }
        .navigationTitle("常青笔记")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新建笔记本", systemImage: "folder.badge.plus") { startNewFolder(parent: "") }
            }
            ToolbarItem(placement: .navigation) {
                Button("账户", systemImage: "person.crop.circle") { showAccount = true }
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
                    let f = engine.createFolder(name: String(name.prefix(100)), parentId: parent)
                    selection = .folder(f.id)
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
            Button("删除「\(f.name)」", role: .destructive) {
                if selection == .folder(f.id) { selection = .all }
                engine.deleteFolder(f.id)
            }
        } message: { _ in
            Text("子笔记本会一起删除，其中的笔记移到回收站。")
        }
    }

    private func row(_ title: String, _ icon: String, count: Int) -> some View {
        Label {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                if count > 0 { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
            }
        } icon: {
            Image(systemName: icon)
        }
    }

    private func startNewFolder(parent: String) {
        nameDraft = ""
        newFolderParent = parent
    }

    private func count(in folder: String) -> Int {
        engine.liveNotes.filter { $0.folderId == folder }.count
    }

    private func folderTree() -> [FolderNode] {
        let byParent = Dictionary(grouping: engine.folders.values, by: \.parentId)
        func build(_ parent: String, depth: Int) -> [FolderNode] {
            guard depth < 64 else { return [] }
            return (byParent[parent] ?? [])
                .sorted { ($0.sort, $0.name) < ($1.sort, $1.name) }
                .map { f in
                    let kids = build(f.id, depth: depth + 1)
                    return FolderNode(folder: f, children: kids.isEmpty ? nil : kids)
                }
        }
        return build("", depth: 0)
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
