import IvynoteKit
import SwiftUI

/// The bookshelf and the paper (guide 11.1): the shelf tree on the left, the
/// open note on the right; on iPhone one at a time.
struct LibraryView: View {
    @Environment(SyncEngine.self) private var engine
    @Environment(EditorHost.self) private var editor
    @Environment(Library.self) private var library
    @Environment(LibraryCatalog.self) private var catalog

    /// The selected row's key; a note can show in several places (pinned,
    /// tags, its notebook), and each row is selected on its own.
    @State private var selection: String?
    @State private var expanded: Set<String> = []
    @State private var showAccount = false
    @State private var showMedia = false
    @State private var showAgenda = false
    @State private var reminderTask: Task<Void, Never>?

    private var selectedNote: String? { selection.flatMap(noteID(fromKey:)) }

    var body: some View {
        NavigationSplitView {
            ShelfView(selection: $selection, expanded: $expanded, showAccount: $showAccount, showMedia: $showMedia, showAgenda: $showAgenda, reveal: reveal)
                .navigationTitle(library.ref.name)
                #if os(iOS)
                // The header row names the library, so the bar stays quiet:
                // on iPhone it is gone (it held nothing), on iPad it keeps
                // the sidebar button.
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) } }
                .modifier(HideBarWhenCompact())
                #endif
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 240, ideal: 296, max: 420)
                #endif
        } detail: {
            if let id = selectedNote, engine.notes[id] != nil {
                NoteEditorView(noteID: id).id(id)
            } else {
                ContentUnavailableView(L.noNoteSelected, systemImage: "note.text")
            }
        }
        .sheet(isPresented: $showAccount) { AccountView() }
        .sheet(isPresented: $showMedia) { MediaLibraryView(openNote: reveal) }
        .sheet(isPresented: $showAgenda) {
            AgendaView { id, line in
                showAgenda = false
                editor.pendingLine = (id, line)
                reveal(id)
            }
        }
        // Reminders follow the notes: the system's notifications are set
        // again a moment after any change (guide 11.8).
        .onChange(of: engine.notes, initial: true) { _, notes in
            reminderTask?.cancel()
            let list = Array(notes.values)
            let id = library.ref.id
            reminderTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                await Reminders.schedule(list, library: id)
            }
        }
        .alert(L.uploadFailedTitle, isPresented: Binding(get: { engine.uploadFailure != nil }, set: { if !$0 { engine.uploadFailure = nil } }),
               presenting: engine.uploadFailure) { _ in
            Button(L.ok, role: .cancel) { engine.uploadFailure = nil }
        } message: { f in
            Text(L.uploadRefused(f.name, f.message))
        }
        .alert(L.conflictTitle, isPresented: Binding(get: { engine.conflict != nil }, set: { if !$0 { engine.conflict = nil } }), presenting: engine.conflict) { c in
            Button(L.openCopy) {
                reveal(c.copyID)
                engine.conflict = nil
            }
            Button(L.ok, role: .cancel) { engine.conflict = nil }
        } message: { c in
            Text(L.conflictMessage(engine.notes[c.noteID].map(displayTitle) ?? L.note))
        }
        .onAppear {
            expanded = ShelfState.load(for: library.ref)
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
        .onChange(of: expanded) { _, keys in ShelfState.save(keys, for: library.ref) }
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

@MainActor
func displayTitle(_ n: Note) -> String {
    n.title.trimmingCharacters(in: .whitespaces).isEmpty ? L.untitled : n.title
}

/// Which branches are open, kept on this device per library (guide 11.2).
/// Under `ivy.lib.<id>.` so removing the library removes it too.
enum ShelfState {
    private static func key(_ ref: LibraryRef) -> String { "ivy.lib.\(ref.id).expanded" }

    static func load(for ref: LibraryRef) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key(ref)) ?? [])
    }

    static func save(_ keys: Set<String>, for ref: LibraryRef) {
        UserDefaults.standard.set(Array(keys), forKey: key(ref))
    }
}

// MARK: Shelf

struct ShelfView: View {
    @Environment(SyncEngine.self) private var engine
    @Binding var selection: String?
    @Binding var expanded: Set<String>
    @Binding var showAccount: Bool
    @Binding var showMedia: Bool
    @Binding var showAgenda: Bool
    let reveal: (String) -> Void

    @AppStorage("ivy.shelf.sort") private var sortBy: Shelf.SortBy = .updated
    @State private var limits: [String: Int] = [:]
    @State private var query = ""
    @State private var newFolderParent: String?
    @State private var renaming: Folder?
    @State private var deleting: Folder?
    @State private var confirmEmpty = false
    @State private var nameDraft = ""
    @State private var editingTag: Tag?

    var body: some View {
        List(selection: $selection) {
            // The library heads the shelf: what it is, how its sync stands,
            // and (as a menu) the way to another one.
            Section {
                LibraryHeader(showAccount: $showAccount, showMedia: $showMedia, showAgenda: $showAgenda)
                    .selectionDisabled()
                    .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                    .listRowSeparator(.hidden)
                    #if os(iOS)
                    .listRowBackground(Color.clear)
                    #endif
            }
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                ForEach(rows) { row in
                    rowView(row)
                        .tag(row.key)
                        .selectionDisabled(row.kind != .note)
                        .contextMenu { menu(for: row) }
                        .swipeActions(edge: .trailing) { swipes(for: row) }
                        .listRowInsets(EdgeInsets(top: row.gap ? ShelfMetrics.gap : 0, leading: 10, bottom: 0, trailing: 12))
                        .listRowSeparator(.hidden)
                }
            } else {
                searchResults
            }
        }
        .listStyle(.sidebar)
        #if os(iOS)
        // The header sits snug above the tree, not a section apart.
        .listSectionSpacing(8)
        .contentMargins(.top, 4, for: .scrollContent)
        #endif
        .environment(\.defaultMinListRowHeight, ShelfMetrics.rowHeight)
        .searchable(text: $query, placement: .sidebar, prompt: L.searchNotes)
        .modifier(NewNoteButton { newNote(in: "") })
        .refreshable { await engine.sync() }
        .alert(L.newFolder, isPresented: Binding(get: { newFolderParent != nil }, set: { if !$0 { newFolderParent = nil } })) {
            TextField(L.name, text: $nameDraft)
            Button(L.cancel, role: .cancel) {}
            Button(L.create) {
                let name = nameDraft.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, let parent = newFolderParent {
                    engine.createFolder(name: String(name.prefix(100)), parentId: parent)
                    if !parent.isEmpty { expanded.insert(parent) }
                }
            }
        }
        .alert(L.renameFolder, isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L.name, text: $nameDraft)
            Button(L.cancel, role: .cancel) {}
            Button(L.save) {
                let name = nameDraft.trimmingCharacters(in: .whitespaces)
                if let f = renaming, !name.isEmpty { engine.renameFolder(f.id, to: String(name.prefix(100))) }
            }
        }
        .confirmationDialog(L.deleteFolderTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { f in
            Button(L.deleteNamed(f.name), role: .destructive) { engine.deleteFolder(f.id) }
        } message: { _ in
            Text(L.deleteFolderMessage)
        }
        .sheet(item: $editingTag) { tag in TagEditor(tagID: tag.id) }
        .confirmationDialog(L.emptyTrashTitle, isPresented: $confirmEmpty) {
            Button(L.emptyTrash, role: .destructive) {
                if let id = selection.flatMap(noteID(fromKey:)), engine.notes[id]?.isTrashed == true { selection = nil }
                engine.emptyTrash()
            }
        } message: {
            Text(L.cannotUndo)
        }
    }

    private var rows: [Shelf.Row] {
        Shelf.build(folders: Array(engine.folders.values), notes: Array(engine.notes.values), tags: Array(engine.tags.values),
                    expanded: expanded, sortBy: sortBy, limits: limits)
    }

    @ViewBuilder private var searchResults: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let hits = Shelf.sortNotes(engine.liveNotes.filter {
            // A protected note is found by its title only (guide 8.4).
            $0.title.localizedCaseInsensitiveContains(q) || (!NoteLock.isEncrypted($0.body) && $0.body.localizedCaseInsensitiveContains(q))
        }, by: sortBy)
        if hits.isEmpty {
            ContentUnavailableView.search(text: q)
        } else {
            ForEach(hits.prefix(200)) { n in
                NoteRow(note: n).tag("s/\(n.id)" as String?)
            }
        }
    }

    /// On the Mac notes are selected by the list itself, so arrow keys and
    /// highlighting work as in Finder. On iPhone and iPad every row is a
    /// full-width button: a list's own selection there competes with the
    /// buttons beside it, and a tap on a note could be lost.
    @ViewBuilder private func rowView(_ row: Shelf.Row) -> some View {
        let label = ShelfRowView(row: row, sortBy: $sortBy, onNewFolder: { startNewFolder(parent: "") }, onNewNote: newNote)
        #if os(macOS)
        let plain = row.kind == .note || row.kind == .heading
        #else
        let plain = row.kind == .heading
        #endif
        if plain {
            label
        } else {
            Button { tap(row) } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        }
    }

    private func tap(_ row: Shelf.Row) {
        switch row.kind {
        case .section:
            let key = Shelf.closedKey(row.key)
            withAnimation(.snappy(duration: 0.2)) {
                if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
            }
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
            #if os(iOS)
            UISelectionFeedbackGenerator().selectionChanged()
            #endif
        case .heading:
            break
        }
    }

    @ViewBuilder private func menu(for row: Shelf.Row) -> some View {
        switch row.kind {
        case .folder:
            if let f = row.folder {
                Button(L.newNote, systemImage: "square.and.pencil") { newNote(in: f.id) }
                Button(L.newSubfolder, systemImage: "folder.badge.plus") { startNewFolder(parent: f.id) }
                Button(L.rename, systemImage: "pencil") { nameDraft = f.name; renaming = f }
                Button(L.delete, systemImage: "trash", role: .destructive) { deleting = f }
            }
        case .note:
            if let n = row.note { NoteMenu(note: n, selection: $selection) }
        case .tag:
            if let t = row.tag {
                Button(L.editTagEllipsis, systemImage: "pencil") { editingTag = t }
            }
        case .group where row.key == Shelf.trashKey && row.count > 0:
            Button(L.emptyTrash, systemImage: "trash.slash", role: .destructive) { confirmEmpty = true }
        case .heading:
            Button(L.newNote, systemImage: "square.and.pencil") { newNote(in: "") }
            Button(L.newFolder, systemImage: "folder.badge.plus") { startNewFolder(parent: "") }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func swipes(for row: Shelf.Row) -> some View {
        if let n = row.note {
            if n.isTrashed {
                Button(L.deleteForever, systemImage: "trash.slash", role: .destructive) {
                    if selection == row.key { selection = nil }
                    engine.deleteNote(n.id)
                }
                Button(L.restore, systemImage: "arrow.uturn.backward") { engine.updateNote(n.id, .init(trashed: false)) }
                    .tint(.green)
            } else {
                Button(L.moveToTrash, systemImage: "trash", role: .destructive) {
                    if selection == row.key { selection = nil }
                    engine.updateNote(n.id, .init(trashed: true))
                }
                Button(n.pinned ? L.unpin : L.pin, systemImage: n.pinned ? "pin.slash" : "pin") {
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

/// Row sizes: compact on the Mac, finger-sized (44pt, Apple's minimum
/// target) on iPhone and iPad.
enum ShelfMetrics {
    #if os(iOS)
    static let rowHeight: CGFloat = 44
    static let gap: CGFloat = 18
    static let font = Font.body
    static let chevron = Font.footnote.weight(.semibold)
    static let chevronWidth: CGFloat = 16
    static let iconWidth: CGFloat = 24
    /// Narrow screens: deep branches indent less so titles keep their room.
    static func indent(_ depth: Int) -> CGFloat {
        CGFloat(min(depth, 4)) * 18 + CGFloat(max(depth - 4, 0)) * 8
    }
    #else
    static let rowHeight: CGFloat = 34
    static let gap: CGFloat = 14
    static let font = Font.body
    static let chevron = Font.caption2.weight(.semibold)
    static let chevronWidth: CGFloat = 12
    static let iconWidth: CGFloat = 20
    static func indent(_ depth: Int) -> CGFloat { CGFloat(depth) * 16 }
    #endif
}

struct ShelfRowView: View {
    let row: Shelf.Row
    @Binding var sortBy: Shelf.SortBy
    let onNewFolder: () -> Void
    let onNewNote: (String) -> Void

    var body: some View {
        switch row.kind {
        case .section:
            // Headed like 笔记, with its count and a quiet arrow to fold it.
            HStack(spacing: 6) {
                Text(row.label).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(row.count)").font(.footnote).monospacedDigit().foregroundStyle(.tertiary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(ShelfMetrics.chevron)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(row.open ? 90 : 0))
                    .frame(width: ShelfMetrics.rowHeight, height: ShelfMetrics.rowHeight)
            }
            .padding(.top, 10)
            .contentShape(Rectangle())
            .accessibilityLabel(row.open ? L.collapsePinned : L.expandPinned)
        case .heading:
            HStack {
                Text(row.label).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Picker(L.sort, selection: $sortBy) {
                        ForEach(Shelf.SortBy.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Divider()
                    Button(L.newNote, systemImage: "square.and.pencil") { onNewNote("") }
                    Button(L.newFolder, systemImage: "folder.badge.plus", action: onNewFolder)
                } label: {
                    Image(systemName: "ellipsis").frame(width: ShelfMetrics.rowHeight, height: ShelfMetrics.rowHeight)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        case .create:
            Label(L.newFolder, systemImage: "plus").foregroundStyle(.secondary)
        case .more:
            HStack(spacing: 6) {
                indent
                Text(L.showMore(min(row.count, Shelf.page), row.count))
                    .font(.footnote).foregroundStyle(.tint)
            }
        default:
            HStack(spacing: 6) {
                indent
                Image(systemName: "chevron.right")
                    .font(ShelfMetrics.chevron)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(row.open ? 90 : 0))
                    .frame(width: ShelfMetrics.chevronWidth)
                    .opacity(row.expandable ? 1 : 0)
                Image(systemName: icon)
                    .foregroundStyle(row.kind == .note ? Color.secondary : Color.accentColor)
                    .frame(width: ShelfMetrics.iconWidth)
                Text(title)
                    .font(ShelfMetrics.font)
                    .lineLimit(1)
                    .foregroundStyle(row.kind == .note && row.label.isEmpty ? .secondary : .primary)
                Spacer(minLength: 4)
                if let n = row.note, n.pinned, !n.isTrashed, row.parent != Shelf.pinnedKey {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                }
                if row.count > 0 {
                    Text("\(row.count)").font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                }
                #if os(iOS)
                if row.kind == .note {
                    Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.quaternary)
                }
                #endif
            }
            .frame(minHeight: ShelfMetrics.rowHeight)
            .contentShape(Rectangle())
        }
    }

    private var indent: some View {
        Color.clear.frame(width: ShelfMetrics.indent(row.depth), height: 1)
    }

    private var title: String {
        switch row.kind {
        case .note: row.label.trimmingCharacters(in: .whitespaces).isEmpty ? L.untitled : row.label
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
            Button(L.restore, systemImage: "arrow.uturn.backward") { engine.updateNote(note.id, .init(trashed: false)) }
            Button(L.deleteForever, systemImage: "trash.slash", role: .destructive) {
                clearIfSelected()
                engine.deleteNote(note.id)
            }
        } else {
            Button(note.pinned ? L.unpin : L.pin, systemImage: note.pinned ? "pin.slash" : "pin") {
                engine.updateNote(note.id, .init(pinned: !note.pinned))
            }
            MoveToFolderMenu(note: note)
            Button(L.moveToTrash, systemImage: "trash", role: .destructive) {
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
        Menu(L.moveTo, systemImage: "folder") {
            option(L.noNotebook, id: "")
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

/// The open library at the head of the shelf: its name and sync status; a
/// tap opens a menu to switch libraries, open a synced library's account,
/// or the library list.
/// On iPhone the header is the page's title (there is no bar above it).
private enum HeaderMetrics {
    #if os(iOS)
    static let icon: CGFloat = 40
    static let name = Font.title2.weight(.bold)
    #else
    static let icon: CGFloat = 34
    static let name = Font.headline
    #endif
}

struct LibraryHeader: View {
    @Environment(LibraryCatalog.self) private var catalog
    @Environment(Library.self) private var library
    @Binding var showAccount: Bool
    @Binding var showMedia: Bool
    @Binding var showAgenda: Bool

    var body: some View {
        Menu {
            Section(L.libraries) {
                ForEach(catalog.libraries) { ref in
                    Button {
                        if ref.id != library.ref.id { catalog.open(ref.id) }
                    } label: {
                        if ref.id == library.ref.id {
                            Label(ref.name, systemImage: "checkmark")
                        } else {
                            Label(ref.name, systemImage: ref.isLocal ? "internaldrive" : "icloud")
                        }
                    }
                }
            }
            Section {
                Button(L.agenda, systemImage: "calendar") { showAgenda = true }
                if !library.ref.isLocal {
                    Button(L.mediaLibraryEllipsis, systemImage: "photo.on.rectangle.angled") { showMedia = true }
                    Button(L.accountAndSync, systemImage: "person.crop.circle") { showAccount = true }
                } else if catalog.library(library.ref.id)?.canTurnOnSync == true {
                    Button(L.turnOnSyncEllipsis, systemImage: "icloud.and.arrow.up") { catalog.turnOnSync(library.ref.id) }
                }
                Button(L.manageLibraries, systemImage: "books.vertical") { catalog.open(nil) }
            }
            Section {
                // A submenu: follow the system, or one language.
                LanguagePicker().pickerStyle(.menu)
            }
        } label: {
            HStack(spacing: 10) {
                LibraryIcon(ref: library.ref, size: HeaderMetrics.icon)
                VStack(alignment: .leading, spacing: 1) {
                    Text(library.ref.name)
                        .font(HeaderMetrics.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    SyncStatusView()
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(L.switchLibrary)
        .accessibilityLabel(L.libraryLabel(library.ref.name))
    }
}

struct SyncStatusView: View {
    @Environment(SyncEngine.self) private var engine

    var body: some View {
        let s = engine.state
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if engine.isLocal {
                    Image(systemName: "icloud.slash")
                    Text(L.localUnsynced)
                } else {
                switch s.status {
                case .syncing:
                    ProgressView().controlSize(.mini)
                    Text(s.initial ? L.downloadingNotes : L.syncing)
                case .offline:
                    Image(systemName: "wifi.slash")
                    Text(s.pending > 0 ? L.offlinePending(s.pending) : L.offline)
                case .error:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(L.syncError).help(s.error ?? "")
                case .idle:
                    if s.pending > 0 {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(L.pending(s.pending))
                    } else if s.lastSyncAt > 0 {
                        Image(systemName: "checkmark.icloud")
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text(L.synced(Date(timeIntervalSince1970: Double(s.lastSyncAt) / 1000).formatted(.relative(presentation: .named).locale(L.locale))))
                        }
                    } else {
                        Text(L.neverSynced)
                    }
                }
                }
            }
            if s.blocked > 0 {
                Text(L.blocked(s.blocked)).foregroundStyle(.orange)
            }
            if s.uploads > 0 && !engine.isLocal {
                Text(L.uploadsPending(s.uploads))
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

/// 新建笔记: on iPhone at the bottom right, where the thumb is and where
/// Notes keeps it, beside the search field; on iPad and the Mac in the
/// sidebar's toolbar, with ⌘N.
private struct NewNoteButton: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let action: () -> Void

    private var button: some View {
        Button(L.newNote, systemImage: "square.and.pencil", action: action)
            .keyboardShortcut("n", modifiers: .command)
    }

    func body(content: Content) -> some View {
        #if os(iOS)
        if sizeClass == .compact {
            if #available(iOS 26, *) {
                content.toolbar {
                    DefaultToolbarItem(kind: .search, placement: .bottomBar)
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) { button }
                }
            } else {
                content.toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Spacer()
                        button
                    }
                }
            }
        } else {
            content.toolbar { ToolbarItem(placement: .primaryAction) { button } }
        }
        #else
        content.toolbar { ToolbarItem(placement: .primaryAction) { button } }
        #endif
    }
}

#if os(iOS)
private struct HideBarWhenCompact: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content.toolbar(sizeClass == .compact ? .hidden : .automatic, for: .navigationBar)
    }
}
#endif
