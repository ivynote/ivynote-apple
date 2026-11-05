import Foundation
import Observation

/// Where the engine stands, for the status line (guide 3.5).
public struct SyncState: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case idle, syncing, offline, error }

    public var status: Status = .idle
    /// Local changes waiting to be pushed (not counting refused ones).
    public var pending = 0
    /// Changes the server refused, kept on this device.
    public var blocked = 0
    public var lastSyncAt: Millis = 0
    /// The first sync of this library: nothing downloaded yet.
    public var initial = false
    public var error: String?
}

/// The server kept a pushed body as a separate note.
public struct ConflictNotice: Equatable, Identifiable, Sendable {
    public var id: String { copyID }
    public let noteID: String
    public let copyID: String
}

/// Local-first sync engine, a port of the web client's
/// (`ivynote/client/packages/core/src/sync/engine.ts`), following guide ch. 6.
///
/// Everything is read from memory, loaded from the local store at start-up.
/// Each local edit is applied at once, persisted shortly after, and queued in
/// an outbox that is pushed in the background. Pulls bring everything after
/// the last seen `seq`; fields with unpushed local edits keep the local value
/// until they are pushed. Note bodies carry the `rev` they were based on, so
/// the server can three-way merge concurrent edits.
@MainActor
@Observable
public final class SyncEngine {
    public private(set) var notes: [String: Note] = [:]
    public private(set) var folders: [String: Folder] = [:]
    public private(set) var tags: [String: Tag] = [:]
    public private(set) var attachments: [String: Attachment] = [:]
    public private(set) var state = SyncState()
    /// Set when the server answers with a conflict copy; cleared by the UI.
    public var conflict: ConflictNotice?
    public private(set) var cursor: Int64 = 0

    public let device: String

    /// Called when the server answers 401: the session is over.
    @ObservationIgnored public var onUnauthorized: (() -> Void)?

    @ObservationIgnored var outbox: [String: OutboxEntry] = [:]
    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored private let transport: SyncTransport
    @ObservationIgnored private var hlc: HLC
    @ObservationIgnored private let now: () -> Millis
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let persistDelay: Duration
    @ObservationIgnored private var syncTimer: Task<Void, Never>?
    @ObservationIgnored private var persistTimer: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var again = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var retryDelay: Duration = .seconds(2)
    @ObservationIgnored private var dirty = Dirty()

    private struct Dirty {
        var notes = Set<String>(), folders = Set<String>(), tags = Set<String>(), outbox = Set<String>()
        var isEmpty: Bool { notes.isEmpty && folders.isEmpty && tags.isEmpty && outbox.isEmpty }
    }

    static let pushBatch = 200
    // Below what the server reads; one larger change still goes out alone.
    static let pushBytes = 6 << 20
    static let maxRetry: Duration = .seconds(60)

    public init(store: LocalStore, transport: SyncTransport, device: String,
                debounce: Duration = .milliseconds(800), persistDelay: Duration = .milliseconds(300),
                now: @escaping () -> Millis = { Millis(Date().timeIntervalSince1970 * 1000) }) {
        self.store = store
        self.transport = transport
        self.device = device
        self.hlc = HLC(node: device)
        self.now = now
        self.debounce = debounce
        self.persistDelay = persistDelay
    }

    /// Loads the local copy. The first `sync()` then downloads a snapshot.
    public func load() throws {
        for n: Note in try store.all(.notes) { notes[n.id] = n }
        for f: Folder in try store.all(.folders) { folders[f.id] = f }
        for t: Tag in try store.all(.tags) { tags[t.id] = t }
        for a: Attachment in try store.all(.attachments) { attachments[a.id] = a }
        for var e: OutboxEntry in try store.all(.outbox) {
            // A restart is a new attempt: the clock or the server may have changed.
            e.blocked = nil
            outbox[e.key] = e
        }
        cursor = store.meta("cursor") ?? 0
        state.lastSyncAt = store.meta("lastSyncAt") ?? 0
        for n in notes.values { observeClock(n.hlc) }
        updateCounts()
    }

    // MARK: Sync loop (guide 6.8)

    /// Pushes, then pulls. Concurrent calls coalesce into one more round.
    public func sync() async {
        guard !stopped else { return }
        if let running {
            again = true
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.again = false
                await self.runOnce()
            } while self.again && !self.stopped
        }
        running = task
        await task.value
        running = nil
    }

    private func runOnce() async {
        syncTimer?.cancel()
        syncTimer = nil
        state.status = .syncing
        state.initial = state.lastSyncAt == 0
        do {
            try await push()
            try await pull()
            retryDelay = .seconds(2)
            let at = now()
            try? store.setMeta("lastSyncAt", at)
            state.lastSyncAt = at
            state.status = .idle
            state.initial = false
            state.error = nil
        } catch let e as APIError where e.status == 401 {
            state.status = .error
            state.error = "unauthorized"
            onUnauthorized?()
        } catch {
            let offline = (error as? APIError)?.isTransient ?? false
            state.status = offline ? .offline : .error
            state.error = offline ? nil : error.localizedDescription
            state.initial = false
            scheduleSync(after: retryDelay)
            retryDelay = min(retryDelay * 2, Self.maxRetry)
        }
    }

    /// Schedules a sync (default: the edit debounce), replacing a scheduled one.
    public func scheduleSync(after delay: Duration? = nil) {
        guard !stopped else { return }
        syncTimer?.cancel()
        let delay = delay ?? debounce
        syncTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.syncTimer = nil
            await self.sync()
        }
    }

    /// Reacts to a server notification (SSE).
    public func onServerSeq(_ seq: Int64) {
        if seq > cursor { Task { await sync() } }
    }

    /// Stops timers. Pending changes stay persisted for the next start.
    public func stop() {
        stopped = true
        syncTimer?.cancel()
        persistNow()
    }

    // MARK: Pull (guide 6.5)

    func pull() async throws {
        let full = cursor == 0
        let res = full ? try await transport.snapshot() : try await transport.pull(since: cursor)
        applyPull(res, snapshot: full)
        cursor = res.seq
        persistNow()
        try store.setMeta("cursor", cursor)
    }

    /// Applies a pull or snapshot. A snapshot replaces entities missing from it.
    func applyPull(_ res: PullResponse, snapshot: Bool) {
        if snapshot {
            prune(&notes, .note, keep: Set(res.notes.map(\.id)), dirty: \.notes)
            prune(&folders, .folder, keep: Set(res.folders.map(\.id)), dirty: \.folders)
            prune(&tags, .tag, keep: Set(res.tags.map(\.id)), dirty: \.tags)
            attachments.removeAll()
            try? store.clear(.attachments)
        }
        for f in res.folders { observeClock(f.hlc); applyRemote(.folder, f, in: &folders, dirty: \.folders) }
        for t in res.tags { observeClock(t.hlc); applyRemote(.tag, t, in: &tags, dirty: \.tags) }
        for n in res.notes { observeClock(n.hlc); applyRemote(.note, n, in: &notes, dirty: \.notes) }
        var put: [(id: String, value: Attachment)] = []
        var gone: [String] = []
        for a in res.attachments {
            if a.deleted { attachments[a.id] = nil; gone.append(a.id) }
            else { attachments[a.id] = a; put.append((a.id, a)) }
        }
        try? store.put(.attachments, put)
        try? store.delete(.attachments, gone)
        updateCounts()
    }

    private func prune<T>(_ map: inout [String: T], _ type: EntityType, keep: Set<String>, dirty path: WritableKeyPath<Dirty, Set<String>>) {
        for id in map.keys where !keep.contains(id) && outbox["\(type.rawValue):\(id)"] == nil {
            map[id] = nil
            dirty[keyPath: path].insert(id)
        }
    }

    private func applyRemote<T: SyncEntity>(_ type: EntityType, _ remote: T, in map: inout [String: T], dirty path: WritableKeyPath<Dirty, Set<String>>) {
        let key = "\(type.rawValue):\(remote.id)"
        let pending = outbox[key]
        dirty[keyPath: path].insert(remote.id)
        if remote.deleted {
            // A tombstone wins over unpushed edits.
            map[remote.id] = nil
            if pending != nil { removeOutbox(key) }
            return
        }
        if pending?.op == .delete { return }
        var merged = remote
        if let pending {
            if let local = map[remote.id] {
                for field in pending.fields.keys { merged.keepField(field, from: local) }
            } else {
                // Written before the entity arrived here, as in a conflict copy.
                for (field, value) in pending.fields { merged.applyField(field, value, now: now()) }
            }
        }
        map[remote.id] = merged
    }

    private func observeClock(_ stamps: [String: String]?) {
        for ts in stamps?.values ?? [:].values { hlc.observe(ts) }
    }

    // MARK: Push (guide 6.3, 6.7)

    func push() async throws {
        let keys = outbox.values.filter { $0.blocked == nil }.sorted { $0.order < $1.order }.map(\.key)
        let encoder = JSONEncoder()
        var i = 0
        while i < keys.count {
            var batch: [OutboxEntry] = []
            var bytes = 0
            while i < keys.count && batch.count < Self.pushBatch {
                guard let e = outbox[keys[i]], e.blocked == nil else { i += 1; continue }
                let size = (try? encoder.encode(e.change).count) ?? 0
                if !batch.isEmpty && bytes + size > Self.pushBytes { break }
                batch.append(e)
                bytes += size
                i += 1
            }
            if !batch.isEmpty { try await send(batch) }
            persistNow()
            updateCounts()
        }
    }

    /// Pushes a batch. A refused one is split until the change at fault is alone.
    private func send(_ batch: [OutboxEntry]) async throws {
        let res: PushResponse
        do {
            res = try await transport.push(batch.map(\.change))
        } catch let e as APIError where e.status == 400 || e.status == 413 {
            if batch.count == 1 {
                let message: String = if case .server(_, let m) = e { m } else { "rejected" }
                applyResult(sent: batch[0], ChangeResult(type: batch[0].type, id: batch[0].id, ok: false, error: message))
                return
            }
            let mid = batch.count / 2
            try await send(Array(batch[..<mid]))
            try await send(Array(batch[mid...]))
            return
        }
        for (sent, r) in zip(batch, res.results) { applyResult(sent: sent, r) }
    }

    func applyResult(sent: OutboxEntry, _ r: ChangeResult) {
        var cur = outbox[sent.key]
        let unchanged = cur != nil && cur!.version == sent.version

        if !r.ok {
            // The edit stays here rather than vanish: it waits for the next
            // edit or restart, and pulls keep its fields.
            if unchanged, var cur {
                cur.blocked = r.error ?? "rejected"
                setOutbox(cur)
            }
            return
        }
        if unchanged { removeOutbox(sent.key); cur = nil }

        switch sent.type {
        case .folder:
            if let s = r.seq, folders[sent.id] != nil { folders[sent.id]!.seq = s; dirty.folders.insert(sent.id) }
            return
        case .tag:
            if let s = r.seq, tags[sent.id] != nil { tags[sent.id]!.seq = s; dirty.tags.insert(sent.id) }
            return
        case .note:
            break
        }

        guard var n = notes[sent.id], sent.op != .delete else { return }
        if let s = r.seq { n.seq = s }
        let bodySent = sent.fields["body"] != nil

        if let copy = r.conflictCopy {
            // The server kept its body; the pushed one lives in the copy, and
            // so does anything written since. The next pull restores the note.
            if var c = cur, let body = c.fields["body"] {
                c.fields["body"] = nil
                c.baseRev = nil
                if c.fields.isEmpty { removeOutbox(c.key) } else { setOutbox(c) }
                enqueue(.note, copy, ["body": body], baseRev: 1)
            }
            notes[n.id] = n
            dirty.notes.insert(n.id)
            conflict = ConflictNotice(noteID: sent.id, copyID: copy)
            return
        }

        if let rev = r.rev {
            if cur == nil {
                n.rev = rev
            } else if bodySent && r.merged != true {
                // Later edits build on the accepted body.
                n.rev = rev
                cur!.baseRev = rev
                setOutbox(cur!)
            } else if !bodySent {
                n.rev = rev
            }
            // Merged while newer local edits wait: keep the old base so the
            // server merges the newer text against it again.
        }
        if r.merged == true, let body = r.body, cur == nil, n.body != body {
            n.body = body
        }
        notes[n.id] = n
        dirty.notes.insert(n.id)
    }

    // MARK: Outbox (guide 6.6)

    private func enqueue(_ type: EntityType, _ id: String, _ fields: [String: JSONValue], delete: Bool = false, baseRev: Int64? = nil) {
        let key = "\(type.rawValue):\(id)"
        let ts = hlc.tick(now: now())
        var e = outbox[key] ?? OutboxEntry(key: key, type: type, id: id, op: .upsert, fields: [:], hlc: ts,
                                           baseRev: nil, device: device, version: 0, order: ts)
        if delete {
            e.op = .delete
            e.fields = [:]
            e.baseRev = nil
        } else {
            e.fields.merge(fields) { $1 }
            if fields["body"] != nil && e.baseRev == nil { e.baseRev = baseRev }
        }
        e.blocked = nil
        e.hlc = ts
        e.version += 1
        setOutbox(e)
        schedulePersist()
        updateCounts()
        scheduleSync()
    }

    private func setOutbox(_ e: OutboxEntry) {
        outbox[e.key] = e
        dirty.outbox.insert(e.key)
    }

    private func removeOutbox(_ key: String) {
        outbox[key] = nil
        dirty.outbox.insert(key)
    }

    private func updateCounts() {
        let blocked = outbox.values.filter { $0.blocked != nil }.count
        state.blocked = blocked
        state.pending = outbox.count - blocked
    }

    // MARK: Persistence

    private func schedulePersist() {
        guard persistTimer == nil else { return }
        persistTimer = Task { [weak self] in
            try? await Task.sleep(for: self?.persistDelay ?? .zero)
            guard let self else { return }
            self.persistTimer = nil
            self.persistNow()
        }
    }

    /// Writes what changed in memory to the local store.
    public func persistNow() {
        persistTimer?.cancel()
        persistTimer = nil
        guard !dirty.isEmpty else { return }
        let d = dirty
        dirty = Dirty()
        func split<T: Encodable>(_ ids: Set<String>, _ map: [String: T]) -> (put: [(id: String, value: T)], del: [String]) {
            var put: [(id: String, value: T)] = []
            var del: [String] = []
            for id in ids { if let v = map[id] { put.append((id, v)) } else { del.append(id) } }
            return (put, del)
        }
        do {
            try store.transaction {
                let n = split(d.notes, notes), f = split(d.folders, folders), t = split(d.tags, tags), o = split(d.outbox, outbox)
                try store.put(.notes, n.put); try store.delete(.notes, n.del)
                try store.put(.folders, f.put); try store.delete(.folders, f.del)
                try store.put(.tags, t.put); try store.delete(.tags, t.del)
                try store.put(.outbox, o.put); try store.delete(.outbox, o.del)
            }
        } catch {
            // Keep the changes in memory and try again with the next write.
            dirty.notes.formUnion(d.notes); dirty.folders.formUnion(d.folders)
            dirty.tags.formUnion(d.tags); dirty.outbox.formUnion(d.outbox)
            state.error = error.localizedDescription
        }
    }

    // MARK: Local edits

    public struct NotePatch: Sendable {
        public var title: String?
        public var body: String?
        public var folderId: String?
        public var tags: [String]?
        public var pinned: Bool?
        public var trashed: Bool?

        public init(title: String? = nil, body: String? = nil, folderId: String? = nil, tags: [String]? = nil, pinned: Bool? = nil, trashed: Bool? = nil) {
            self.title = title; self.body = body; self.folderId = folderId; self.tags = tags; self.pinned = pinned; self.trashed = trashed
        }
    }

    @discardableResult
    public func createNote(title: String = "", body: String = "", folderId: String = "", tags: [String] = [], pinned: Bool = false) -> Note {
        let t = now()
        var id = newEntityID()
        while notes[id] != nil { id = newEntityID() }
        let note = Note(id: id, folderId: folderId, title: title, body: body, tags: tags, pinned: pinned, createdAt: t, updatedAt: t)
        notes[id] = note
        dirty.notes.insert(id)
        var fields: [String: JSONValue] = ["title": .string(title), "body": .string(body), "createdAt": .int(t)]
        if !folderId.isEmpty { fields["folderId"] = .string(folderId) }
        if !tags.isEmpty { fields["tags"] = .array(tags.map { .string($0) }) }
        if pinned { fields["pinned"] = .bool(true) }
        enqueue(.note, id, fields, baseRev: 0)
        return note
    }

    public func updateNote(_ id: String, _ patch: NotePatch) {
        guard var n = notes[id] else { return }
        var fields: [String: JSONValue] = [:]
        if let v = patch.title, v != n.title { n.title = v; fields["title"] = .string(v) }
        if let v = patch.body, v != n.body { n.body = v; fields["body"] = .string(v) }
        if let v = patch.folderId, v != n.folderId { n.folderId = v; fields["folderId"] = .string(v) }
        if let v = patch.tags, v != n.tags { n.tags = v; fields["tags"] = .array(v.map { .string($0) }) }
        if let v = patch.pinned, v != n.pinned { n.pinned = v; fields["pinned"] = .bool(v) }
        if let v = patch.trashed, v != n.isTrashed { n.trashedAt = v ? now() : 0; fields["trashed"] = .bool(v) }
        guard !fields.isEmpty else { return }
        n.updatedAt = now()
        notes[id] = n
        dirty.notes.insert(id)
        enqueue(.note, id, fields, baseRev: n.rev)
    }

    /// Permanently deletes a note.
    public func deleteNote(_ id: String) {
        guard notes.removeValue(forKey: id) != nil else { return }
        dirty.notes.insert(id)
        enqueue(.note, id, [:], delete: true)
    }

    /// Permanently deletes every note in the trash.
    public func emptyTrash() {
        for n in notes.values where n.isTrashed { deleteNote(n.id) }
    }

    @discardableResult
    public func createFolder(name: String, parentId: String = "") -> Folder {
        let t = now()
        let sort = (folders.values.filter { $0.parentId == parentId }.map(\.sort).max() ?? 0) + 1
        let f = Folder(id: newEntityID(), parentId: parentId, name: name, sort: sort, createdAt: t, updatedAt: t)
        folders[f.id] = f
        dirty.folders.insert(f.id)
        enqueue(.folder, f.id, ["name": .string(name), "parentId": .string(parentId), "sort": .double(sort)])
        return f
    }

    public func renameFolder(_ id: String, to name: String) {
        guard var f = folders[id], f.name != name else { return }
        f.name = name
        f.updatedAt = now()
        folders[id] = f
        dirty.folders.insert(id)
        enqueue(.folder, id, ["name": .string(name)])
    }

    /// Whether folder `id` may move under `parent` without a cycle (depth ≤ 64).
    public func canMoveFolder(_ id: String, to parent: String) -> Bool {
        var p = parent
        var depth = 0
        while !p.isEmpty {
            if p == id || depth > 64 { return false }
            guard let f = folders[p] else { return false }
            p = f.parentId
            depth += 1
        }
        return true
    }

    public func moveFolder(_ id: String, to parent: String) {
        guard var f = folders[id], f.parentId != parent, canMoveFolder(id, to: parent) else { return }
        f.parentId = parent
        f.updatedAt = now()
        folders[id] = f
        dirty.folders.insert(id)
        enqueue(.folder, id, ["parentId": .string(parent)])
    }

    /// Deletes a folder tree; its notes go to the trash, as on the server.
    public func deleteFolder(_ id: String) {
        guard folders[id] != nil else { return }
        var doomed: Set<String> = [id]
        var grew = true
        while grew {
            grew = false
            for f in folders.values where !doomed.contains(f.id) && doomed.contains(f.parentId) {
                doomed.insert(f.id)
                grew = true
            }
        }
        let t = now()
        for var n in notes.values where doomed.contains(n.folderId) {
            n.folderId = ""
            if n.trashedAt == 0 { n.trashedAt = t }
            notes[n.id] = n
            dirty.notes.insert(n.id)
        }
        for fid in doomed {
            folders[fid] = nil
            dirty.folders.insert(fid)
        }
        enqueue(.folder, id, [:], delete: true)
    }

    @discardableResult
    public func createTag(name: String, color: String = "") -> Tag {
        let t = now()
        var clean = name.trimmingCharacters(in: .whitespaces)
        while clean.hasPrefix("#") { clean.removeFirst() }
        let tag = Tag(id: newEntityID(), name: clean, color: color, createdAt: t, updatedAt: t)
        tags[tag.id] = tag
        dirty.tags.insert(tag.id)
        enqueue(.tag, tag.id, ["name": .string(clean), "color": .string(color)])
        return tag
    }

    public func deleteTag(_ id: String) {
        guard tags.removeValue(forKey: id) != nil else { return }
        dirty.tags.insert(id)
        for var n in notes.values where n.tags.contains(id) {
            n.tags.removeAll { $0 == id }
            notes[n.id] = n
            dirty.notes.insert(n.id)
        }
        enqueue(.tag, id, [:], delete: true)
    }

    // MARK: Queries

    public var liveNotes: [Note] { notes.values.filter { !$0.isTrashed && !$0.deleted } }
    public var trashedNotes: [Note] { notes.values.filter(\.isTrashed) }
}
