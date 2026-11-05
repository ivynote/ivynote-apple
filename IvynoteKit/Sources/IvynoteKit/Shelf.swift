import Foundation

/// The bookshelf (guide 11.2): one tree of notebooks and notes, flattened
/// into rows. A port of the web client's `packages/core/src/tree.ts`, so both
/// clients show the same shelf.
///
/// Order: pinned (when any), the "notes" heading, the notebook tree
/// (sub-notebooks before notes), notes at the root, tags (when any), trash.
public enum Shelf {
    /// Notes shown per branch before a "show more" row.
    public static let page = 100

    public enum SortBy: String, CaseIterable, Sendable {
        case updated, created, title

        public var label: String {
            switch self {
            case .updated: "更新时间"
            case .created: "创建时间"
            case .title: "标题"
            }
        }
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public enum Kind: Sendable { case group, heading, create, folder, tag, note, more }

        /// Unique in the tree; folders and groups use it as their expansion key.
        public let key: String
        public let kind: Kind
        public let depth: Int
        /// Key of the enclosing row, empty at the top level.
        public let parent: String
        public let label: String
        public let count: Int
        public let expandable: Bool
        public let open: Bool
        /// Sets the row apart from the one above.
        public var gap = false
        /// The notebook a new note made from this row goes into.
        public var folderID: String?
        public var folder: Folder?
        public var tag: Tag?
        public var note: Note?

        public var id: String { key }
    }

    // Expansion keys of the groups.
    public static let pinnedKey = "v:pinned"
    public static let tagsKey = "v:tags"
    public static let trashKey = "v:trash"

    public static func sortNotes(_ list: [Note], by: SortBy, trash: Bool = false) -> [Note] {
        list.sorted { a, b in
            if !trash && a.pinned != b.pinned { return a.pinned }
            switch by {
            case .title:
                // Untitled last; Chinese collation, as the web's localeCompare('zh').
                if a.title.isEmpty != b.title.isEmpty { return !a.title.isEmpty }
                let order = a.title.compare(b.title, options: [.caseInsensitive, .numeric], locale: Locale(identifier: "zh"))
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            case .created:
                return a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id < b.id
            case .updated:
                if trash && a.trashedAt != b.trashedAt { return a.trashedAt > b.trashedAt }
                return a.updatedAt != b.updatedAt ? a.updatedAt > b.updatedAt : a.id < b.id
            }
        }
    }

    /// Live notes in each notebook, sub-notebooks included.
    public static func folderTotals(folders: [Folder], notes: [Note]) -> [String: Int] {
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var direct: [String: Int] = [:]
        for n in notes where !n.isTrashed { direct[n.folderId, default: 0] += 1 }
        var out: [String: Int] = [:]
        for f in folders {
            let own = direct[f.id] ?? 0
            var p: Folder? = f
            var depth = 0
            while let cur = p, depth < 64 {
                out[cur.id, default: 0] += own
                p = byID[cur.parentId]
                depth += 1
            }
        }
        return out
    }

    public static func build(folders: [Folder], notes: [Note], tags: [Tag], expanded: Set<String>,
                             sortBy: SortBy, limits: [String: Int] = [:]) -> [Row] {
        var rows: [Row] = []
        let live = notes.filter { !$0.isTrashed }
        let trashed = notes.filter(\.isTrashed)
        let ids = Set(folders.map(\.id))

        var kids: [String: [Folder]] = [:]
        for f in folders {
            // A notebook whose parent is gone shows at the top level.
            kids[ids.contains(f.parentId) ? f.parentId : "", default: []].append(f)
        }
        for k in kids.keys {
            kids[k]!.sort { ($0.sort, $0.name, $0.id) < ($1.sort, $1.name, $1.id) }
        }
        // A note whose notebook is gone must still be somewhere: it falls to the root.
        var filed: [String: [Note]] = [:]
        for n in live { filed[ids.contains(n.folderId) ? n.folderId : "", default: []].append(n) }
        let totals = folderTotals(folders: folders, notes: notes)

        func noteRows(_ list: [Note], parent: String, depth: Int, trash: Bool = false, folderID: String? = nil) {
            let sorted = sortNotes(list, by: sortBy, trash: trash)
            let shown = limits[parent] ?? page
            for note in sorted.prefix(shown) {
                rows.append(Row(key: "\(parent)/\(note.id)", kind: .note, depth: depth, parent: parent, label: note.title,
                                count: 0, expandable: false, open: false, folderID: folderID, note: note))
            }
            if sorted.count > shown {
                rows.append(Row(key: "\(parent)/more", kind: .more, depth: depth, parent: parent, label: "",
                                count: sorted.count - shown, expandable: false, open: false))
            }
        }

        func group(_ key: String, _ label: String, _ list: [Note], trash: Bool = false, gap: Bool = false) {
            let open = expanded.contains(key) && !list.isEmpty
            var row = Row(key: key, kind: .group, depth: 0, parent: "", label: label, count: list.count,
                          expandable: !list.isEmpty, open: open)
            row.gap = gap
            rows.append(row)
            if open { noteRows(list, parent: key, depth: 1, trash: trash) }
        }

        func folderRows(_ parent: String, _ depth: Int) {
            for folder in kids[parent] ?? [] {
                let subs = kids[folder.id] ?? []
                let own = filed[folder.id] ?? []
                let expandable = !subs.isEmpty || !own.isEmpty
                let open = expanded.contains(folder.id) && expandable
                rows.append(Row(key: folder.id, kind: .folder, depth: depth, parent: parent, label: folder.name,
                                count: totals[folder.id] ?? 0, expandable: expandable, open: open,
                                folderID: folder.id, folder: folder))
                guard open else { continue }
                // Sub-notebooks first, as in a file manager that sorts folders on top.
                if depth < 64 { folderRows(folder.id, depth + 1) }
                noteRows(own, parent: folder.id, depth: depth + 1, folderID: folder.id)
            }
        }

        let pinned = live.filter(\.pinned)
        if !pinned.isEmpty { group(pinnedKey, "置顶", pinned) }

        rows.append(Row(key: "h:notes", kind: .heading, depth: 0, parent: "", label: "笔记", count: 0,
                        expandable: false, open: false, folderID: ""))
        if !folders.isEmpty {
            folderRows("", 0)
        } else {
            rows.append(Row(key: "h:create", kind: .create, depth: 0, parent: "", label: "新建笔记本", count: 0,
                            expandable: false, open: false))
        }
        // Notes outside any notebook sit below them, like files at the root of a drive.
        noteRows(filed[""] ?? [], parent: "", depth: 0, folderID: "")

        if !tags.isEmpty {
            let open = expanded.contains(tagsKey)
            var row = Row(key: tagsKey, kind: .group, depth: 0, parent: "", label: "标签", count: 0, expandable: true, open: open)
            row.gap = true
            rows.append(row)
            if open {
                for tag in tags.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                    let key = "t:" + tag.id
                    let list = live.filter { $0.tags.contains(tag.id) }
                    let isOpen = expanded.contains(key) && !list.isEmpty
                    var r = Row(key: key, kind: .tag, depth: 1, parent: tagsKey, label: tag.name, count: list.count,
                                expandable: !list.isEmpty, open: isOpen)
                    r.tag = tag
                    rows.append(r)
                    if isOpen { noteRows(list, parent: key, depth: 2) }
                }
            }
        }
        group(trashKey, "回收站", trashed, trash: true, gap: tags.isEmpty)
        return rows
    }

    /// The branches to open so that a note shows up where it lives.
    public static func revealKeys(for note: Note, folders: [String: Folder]) -> [String] {
        if note.isTrashed { return [trashKey] }
        var path: [String] = []
        var id = note.folderId
        var depth = 0
        while let f = folders[id], depth < 64 {
            path.insert(f.id, at: 0)
            id = f.parentId
            depth += 1
        }
        return path
    }

    /// The key of the row where a note lives (not its pinned or tag copies).
    public static func homeKey(for note: Note, folders: [String: Folder]) -> String {
        if note.isTrashed { return "\(trashKey)/\(note.id)" }
        let parent = folders[note.folderId] != nil ? note.folderId : ""
        return "\(parent)/\(note.id)"
    }
}
