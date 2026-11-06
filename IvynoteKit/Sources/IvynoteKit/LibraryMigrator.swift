import Foundation

/// Turns on sync for a local library: copies it into a newly registered,
/// empty account (guide 6.11; the desktop client's `core/src/promote.ts`).
///
/// A local library keeps no outbox, so it cannot simply start syncing; its
/// content is uploaded once instead. Only an empty account takes it, so
/// nothing on the server is ever merged with it. Ids are kept, which makes a
/// retry after an interruption safe: the server ignores writes that change
/// nothing, and an account holding only this library's own ids counts as a
/// run to resume.
///
/// The Apple client has no file uploads, so its local libraries hold no
/// attachments; only folders, tags and notes move.
public struct LibraryMigrator: Sendable {
    public struct Content: Sendable {
        public var folders: [Folder]
        public var tags: [Tag]
        public var notes: [Note]

        public init(folders: [Folder], tags: [Tag], notes: [Note]) {
            self.folders = folders
            self.tags = tags
            self.notes = notes
        }

        /// Reads a library's database directly; the library should not be open.
        public static func read(from url: URL) throws -> Content {
            let store = try LocalStore(url: url)
            return Content(folders: try store.all(.folders), tags: try store.all(.tags), notes: try store.all(.notes))
        }
    }

    public struct Progress: Equatable, Sendable {
        public enum Phase: Sendable { case check, notes, done }
        public var phase: Phase
        public var done: Int
        public var total: Int
    }

    public struct Result: Equatable, Sendable {
        public var notes = 0
        /// Changes the server refused: `type:id` and its reason.
        public var rejected: [String] = []
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case accountNotEmpty

        public var errorDescription: String? {
            "这个账户里已经有笔记。本地笔记库只能迁移到新注册的空账户。"
        }
    }

    static let batchChanges = 200
    static let batchBytes = 2 << 20

    let api: APIClient
    let device: String
    let now: @Sendable () -> Millis

    /// `api` must carry the new account's token.
    public init(api: APIClient, device: String, now: @escaping @Sendable () -> Millis = { Millis(Date().timeIntervalSince1970 * 1000) }) {
        self.api = api
        self.device = device
        self.now = now
    }

    public func run(_ content: Content, progress: @Sendable (Progress) async -> Void = { _ in }) async throws -> Result {
        let folders = Self.parentsFirst(content.folders.filter { !$0.deleted })
        let tags = content.tags.filter { !$0.deleted }
        let notes = content.notes.filter { !$0.deleted }

        await progress(Progress(phase: .check, done: 0, total: 1))
        let existing = try await api.pull(since: 0)
        var ours = Set(folders.map(\.id))
        ours.formUnion(tags.map(\.id))
        ours.formUnion(notes.map(\.id))
        var theirs: [String] = []
        theirs += existing.notes.filter { !$0.deleted }.map(\.id)
        theirs += existing.folders.filter { !$0.deleted }.map(\.id)
        theirs += existing.tags.filter { !$0.deleted }.map(\.id)
        let strayFiles = existing.attachments.contains { !$0.deleted }
        if strayFiles || theirs.contains(where: { !ours.contains($0) }) { throw Failure.accountNotEmpty }

        var clock = HLC(node: device)
        var changes: [Change] = []
        for f in folders {
            changes.append(Change(type: .folder, id: f.id, op: .upsert,
                                  fields: ["name": .string(f.name), "parentId": .string(f.parentId), "sort": .double(f.sort)],
                                  hlc: clock.tick(now: now()), baseRev: nil, device: device))
        }
        for t in tags {
            changes.append(Change(type: .tag, id: t.id, op: .upsert,
                                  fields: ["name": .string(t.name), "color": .string(t.color)],
                                  hlc: clock.tick(now: now()), baseRev: nil, device: device))
        }
        for n in notes {
            var fields: [String: JSONValue] = ["title": .string(n.title), "body": .string(n.body), "createdAt": .int(n.createdAt)]
            if !n.folderId.isEmpty { fields["folderId"] = .string(n.folderId) }
            if !n.tags.isEmpty { fields["tags"] = .array(n.tags.map { .string($0) }) }
            if n.pinned { fields["pinned"] = .bool(true) }
            if n.isTrashed { fields["trashed"] = .bool(true) }
            changes.append(Change(type: .note, id: n.id, op: .upsert, fields: fields,
                                  hlc: clock.tick(now: now()), baseRev: 0, device: device))
        }

        var result = Result()
        var sent = 0
        var notesSent = 0
        let encoder = JSONEncoder()
        while sent < changes.count {
            var batch: [Change] = []
            var bytes = 0
            while sent + batch.count < changes.count, batch.count < Self.batchChanges {
                let c = changes[sent + batch.count]
                let size = (try? encoder.encode(c).count) ?? 0
                if !batch.isEmpty, bytes + size > Self.batchBytes { break }
                batch.append(c)
                bytes += size
            }
            let res = try await api.push(batch)
            for r in res.results {
                if !r.ok { result.rejected.append("\(r.type.rawValue):\(r.id) \(r.error ?? "refused")") }
                else if r.type == .note { result.notes += 1 }
            }
            sent += batch.count
            notesSent += batch.filter { $0.type == .note }.count
            await progress(Progress(phase: .notes, done: notesSent, total: notes.count))
        }
        await progress(Progress(phase: .done, done: notes.count, total: notes.count))
        return result
    }

    /// Parents before children, so every parentId points at a folder the server already has.
    static func parentsFirst(_ folders: [Folder]) -> [Folder] {
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Folder] = []
        var seen = Set<String>()
        func visit(_ f: Folder, _ path: inout Set<String>) {
            if seen.contains(f.id) || path.contains(f.id) { return }
            path.insert(f.id)
            if !f.parentId.isEmpty, let parent = byID[f.parentId] { visit(parent, &path) }
            seen.insert(f.id)
            out.append(f)
        }
        for f in folders {
            var path = Set<String>()
            visit(f, &path)
        }
        return out
    }
}
