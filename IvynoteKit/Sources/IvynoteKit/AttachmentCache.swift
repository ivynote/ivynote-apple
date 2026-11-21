import Foundation
import Observation

/// User-configurable local attachment cache policy (shared across libraries on this device).
@MainActor
@Observable
public final class AttachmentCacheSettings {
    public static let shared = AttachmentCacheSettings()

    /// Default cache cap: 500 MB.
    public static let defaultMaxBytes: Int64 = 500 * 1024 * 1024

    /// Preset options in bytes (`0` = unlimited).
    public static let presets: [Int64] = [
        100 * 1024 * 1024,
        250 * 1024 * 1024,
        500 * 1024 * 1024,
        1024 * 1024 * 1024,
        2 * 1024 * 1024 * 1024,
        5 * 1024 * 1024 * 1024,
        0,
    ]

    static let localFirstKey = "ivy.attachmentCache.localFirst"
    static let maxBytesKey = "ivy.attachmentCache.maxBytes"

    /// Local-first mode: read attachments from local cache first and keep
    /// uploaded / downloaded attachments cached on disk up to `maxBytes`.
    public var localFirst: Bool {
        didSet {
            guard localFirst != oldValue else { return }
            defaults.set(localFirst, forKey: Self.localFirstKey)
            notifyChange()
        }
    }

    /// Maximum size of synced attachment cache on disk in bytes (`0` = unlimited).
    public var maxBytes: Int64 {
        didSet {
            let clamped = max(0, maxBytes)
            if clamped != maxBytes {
                maxBytes = clamped
                return
            }
            guard maxBytes != oldValue else { return }
            defaults.set(maxBytes, forKey: Self.maxBytesKey)
            notifyChange()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observers: [UUID: @MainActor (Bool, Int64) -> Void] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.localFirstKey) != nil {
            localFirst = defaults.bool(forKey: Self.localFirstKey)
        } else {
            localFirst = true
        }
        if defaults.object(forKey: Self.maxBytesKey) != nil {
            maxBytes = max(0, Int64(defaults.integer(forKey: Self.maxBytesKey)))
            if let num = defaults.object(forKey: Self.maxBytesKey) as? NSNumber {
                maxBytes = max(0, num.int64Value)
            }
        } else {
            maxBytes = Self.defaultMaxBytes
        }
    }

    /// Registers a listener invoked whenever `localFirst` or `maxBytes` changes.
    /// Returns a token that removes the listener when passed to `removeObserver`.
    @discardableResult
    public func addObserver(_ handler: @escaping @MainActor (Bool, Int64) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func notifyChange() {
        let lf = localFirst
        let limit = maxBytes
        for handler in observers.values {
            handler(lf, limit)
        }
    }
}

/// Metadata for one synced attachment file cached in the library's local attachment store.
public struct AttachmentCacheEntry: Codable, Equatable, Sendable {
    /// `<id>` for full file, `<id>:thumb` for thumbnail.
    public var key: String
    public var attachmentID: String
    public var isThumb: Bool
    /// File name on disk inside the library's `attachments/` folder.
    public var file: String
    public var mime: String
    public var size: Int64
    public var createdAt: Millis
    public var lastAccessedAt: Millis
    public var accessCount: Int64

    public init(key: String, attachmentID: String, isThumb: Bool, file: String, mime: String,
                size: Int64, createdAt: Millis, lastAccessedAt: Millis, accessCount: Int64 = 1) {
        self.key = key
        self.attachmentID = attachmentID
        self.isThumb = isThumb
        self.file = file
        self.mime = mime
        self.size = size
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        self.accessCount = accessCount
    }

    /// Heat score used for eviction: combines recency (`lastAccessedAt`) with a bounded
    /// frequency bonus (+6 hours per repeat access, capped at +3.5 days). Lower = colder.
    public var heatScore: Int64 {
        let bonusSteps = min(max(accessCount - 1, 0), 14)
        return lastAccessedAt &+ bonusSteps &* (6 * 3_600 * 1_000)
    }
}

/// Manages one library's local attachment cache (`attachments/` next to `library.sqlite`).
///
/// Pending uploads (`local-*` files in `uploads/`) are NOT tracked here and are never
/// evicted by cache limits. Once a pending upload finishes syncing, its file is promoted
/// into this cache under the server's attachment ID so it displays immediately without
/// being re-downloaded, and is then governed by the configurable access-based cache rules.
@MainActor
@Observable
public final class AttachmentStore {
    public private(set) var totalBytes: Int64 = 0
    public private(set) var entryCount: Int = 0
    public private(set) var localFirst: Bool
    public private(set) var maxBytes: Int64

    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored public let cacheDir: URL
    @ObservationIgnored private let now: () -> Millis
    @ObservationIgnored private let settings: AttachmentCacheSettings?
    @ObservationIgnored private var observerToken: UUID?
    @ObservationIgnored private var entries: [String: AttachmentCacheEntry] = [:]
    /// Runtime alias map (`local-xxx` -> `remoteID`) so in-flight loads keep working
    /// seamlessly while note links are being normalized.
    @ObservationIgnored private var aliases: [String: String] = [:]
    @ObservationIgnored private var dirtyKeys = Set<String>()
    @ObservationIgnored private var persistTimer: Task<Void, Never>?

    public init(store: LocalStore,
                cacheDir: URL? = nil,
                settings: AttachmentCacheSettings? = .shared,
                localFirst: Bool? = nil,
                maxBytes: Int64? = nil,
                now: @escaping () -> Millis = { Millis(Date().timeIntervalSince1970 * 1000) }) {
        self.store = store
        self.cacheDir = cacheDir ?? store.attachmentsURL ?? FileManager.default.temporaryDirectory
            .appending(path: "ivy-attachments-\(UUID().uuidString)", directoryHint: .isDirectory)
        self.settings = settings
        self.localFirst = localFirst ?? settings?.localFirst ?? true
        self.maxBytes = max(0, maxBytes ?? settings?.maxBytes ?? AttachmentCacheSettings.defaultMaxBytes)
        self.now = now
        if let settings {
            observerToken = settings.addObserver { [weak self] lf, limit in
                self?.applyPolicy(localFirst: lf, maxBytes: limit)
            }
        }
    }

    deinit {
        persistTimer?.cancel()
    }

    public func stop() {
        persistTimer?.cancel()
        persistTimer = nil
        persistNow()
        if let token = observerToken, let settings {
            settings.removeObserver(token)
            observerToken = nil
        }
    }

    // MARK: Lifecycle

    /// Loads cache metadata from SQLite, reconciles with files on disk, and enforces limits.
    public func load() throws {
        entries.removeAll()
        let fm = FileManager.default
        let rows: [AttachmentCacheEntry] = try store.all(.cache)
        var staleKeys: [String] = []
        var liveFiles = Set<String>()
        for row in rows {
            let fileURL = cacheDir.appending(path: row.file)
            if fm.fileExists(atPath: fileURL.path) {
                entries[row.key] = row
                liveFiles.insert(row.file)
            } else {
                staleKeys.append(row.key)
            }
        }
        if !staleKeys.isEmpty {
            try? store.delete(.cache, staleKeys)
        }
        // Clean up orphaned files left on disk after a crash.
        if let files = try? fm.contentsOfDirectory(atPath: cacheDir.path) {
            for name in files where !liveFiles.contains(name) {
                try? fm.removeItem(at: cacheDir.appending(path: name))
            }
        }
        recalcStats()
        evictIfNeeded()
    }

    // MARK: Aliases

    public func registerAlias(localID: String, remoteID: String) {
        aliases[localID] = remoteID
    }

    public func canonicalID(_ id: String) -> String {
        aliases[id] ?? id
    }

    // MARK: Lookup & Storage

    public static func cacheKey(id: String, thumb: Bool) -> String {
        thumb ? "\(id):thumb" : id
    }

    private static func fileName(id: String, thumb: Bool) -> String {
        let safe = id.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        return thumb ? "\(safe).thumb" : safe
    }

    /// Returns a locally cached file if present (and updates its access metadata).
    /// When `thumb` is requested and no separate thumbnail is cached, falls back to the
    /// cached full file so newly uploaded images never need a thumbnail round-trip.
    public func cachedFile(id: String, thumb: Bool = false) -> (url: URL, mime: String)? {
        guard localFirst else { return nil }
        let cid = canonicalID(id)
        if thumb {
            if let hit = touchAndResolve(key: Self.cacheKey(id: cid, thumb: true)) {
                return hit
            }
            return touchAndResolve(key: Self.cacheKey(id: cid, thumb: false))
        }
        return touchAndResolve(key: Self.cacheKey(id: cid, thumb: false))
    }

    /// Non-mutating inspection for tests and diagnostics.
    public func entry(id: String, thumb: Bool = false) -> AttachmentCacheEntry? {
        entries[Self.cacheKey(id: canonicalID(id), thumb: thumb)]
    }

    private func touchAndResolve(key: String) -> (url: URL, mime: String)? {
        guard var entry = entries[key] else { return nil }
        let url = cacheDir.appending(path: entry.file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            entries.removeValue(forKey: key)
            try? store.delete(.cache, [key])
            recalcStats()
            return nil
        }
        entry.lastAccessedAt = now()
        entry.accessCount += 1
        entries[key] = entry
        dirtyKeys.insert(key)
        schedulePersist()
        return (url, entry.mime)
    }

    /// Writes a downloaded attachment (or thumbnail) into the local cache.
    @discardableResult
    public func store(id: String, thumb: Bool = false, data: Data, mime: String) -> URL? {
        guard localFirst else { return nil }
        let cid = canonicalID(id)
        let size = Int64(data.count)
        if maxBytes > 0 && size > maxBytes {
            return nil
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let file = Self.fileName(id: cid, thumb: thumb)
            let dest = cacheDir.appending(path: file)
            try data.write(to: dest, options: [.atomic])
            recordEntry(id: cid, thumb: thumb, file: file, mime: mime, size: size)
            return dest
        } catch {
            return nil
        }
    }

    /// Promotes a just-uploaded local file into the synced attachment cache under
    /// `remoteID`, avoiding any re-download from the server. Does not remove
    /// `uploadURL` so the caller can commit normalized note bodies before deleting
    /// the staging copy (crash-safe). On APFS, `copyItem` is copy-on-write.
    public func promote(from uploadURL: URL, localID: String, to remoteID: String, mime: String) {
        registerAlias(localID: localID, remoteID: remoteID)
        let fm = FileManager.default
        guard localFirst else { return }
        let key = Self.cacheKey(id: remoteID, thumb: false)
        // Already cached under remoteID (e.g. duplicate upload): just touch it.
        if var existing = entries[key], fm.fileExists(atPath: cacheDir.appending(path: existing.file).path) {
            existing.lastAccessedAt = now()
            existing.accessCount += 1
            entries[key] = existing
            try? store.put(.cache, [(id: key, value: existing)])
            return
        }
        let size = (try? fm.attributesOfItem(atPath: uploadURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        if maxBytes > 0 && size > maxBytes {
            return
        }
        do {
            try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let file = Self.fileName(id: remoteID, thumb: false)
            let dest = cacheDir.appending(path: file)
            if fm.fileExists(atPath: dest.path) {
                try? fm.removeItem(at: dest)
            }
            try fm.copyItem(at: uploadURL, to: dest)
            recordEntry(id: remoteID, thumb: false, file: file, mime: mime, size: size)
        } catch {
            if let data = try? Data(contentsOf: uploadURL) {
                _ = store(id: remoteID, thumb: false, data: data, mime: mime)
            }
        }
    }

    private func recordEntry(id: String, thumb: Bool, file: String, mime: String, size: Int64) {
        let key = Self.cacheKey(id: id, thumb: thumb)
        let t = now()
        let prev = entries[key]
        let entry = AttachmentCacheEntry(
            key: key,
            attachmentID: id,
            isThumb: thumb,
            file: file,
            mime: mime.isEmpty ? "application/octet-stream" : mime,
            size: size,
            createdAt: prev?.createdAt ?? t,
            lastAccessedAt: t,
            accessCount: (prev?.accessCount ?? 0) + 1
        )
        entries[key] = entry
        dirtyKeys.remove(key)
        try? store.put(.cache, [(id: key, value: entry)])
        recalcStats()
        evictIfNeeded()
    }

    // MARK: Removal & Eviction

    /// Removes cached files (full and thumbnail) for a deleted/purged attachment.
    public func remove(attachmentID: String) {
        let keys = [Self.cacheKey(id: attachmentID, thumb: false), Self.cacheKey(id: attachmentID, thumb: true)]
        var removed: [String] = []
        let fm = FileManager.default
        for key in keys {
            if let entry = entries.removeValue(forKey: key) {
                try? fm.removeItem(at: cacheDir.appending(path: entry.file))
                dirtyKeys.remove(key)
                removed.append(key)
            }
        }
        if !removed.isEmpty {
            try? store.delete(.cache, removed)
            recalcStats()
        }
    }

    /// Updates local-first and size-limit policy, immediately evicting if needed.
    public func applyPolicy(localFirst: Bool, maxBytes: Int64) {
        self.localFirst = localFirst
        self.maxBytes = max(0, maxBytes)
        evictIfNeeded()
    }

    /// Evicts the coldest synced cache entries until within `maxBytes` (or clears all if `!localFirst`).
    public func evictIfNeeded() {
        if !localFirst {
            if !entries.isEmpty { clear() }
            return
        }
        guard maxBytes > 0, totalBytes > maxBytes else { return }
        let sorted = entries.values.sorted { a, b in
            if a.heatScore != b.heatScore { return a.heatScore < b.heatScore }
            if a.lastAccessedAt != b.lastAccessedAt { return a.lastAccessedAt < b.lastAccessedAt }
            if a.size != b.size { return a.size > b.size }
            return a.key < b.key
        }
        let fm = FileManager.default
        var bytes = totalBytes
        var evicted: [String] = []
        for entry in sorted {
            guard bytes > maxBytes else { break }
            entries.removeValue(forKey: entry.key)
            dirtyKeys.remove(entry.key)
            try? fm.removeItem(at: cacheDir.appending(path: entry.file))
            bytes -= entry.size
            evicted.append(entry.key)
        }
        if !evicted.isEmpty {
            try? store.delete(.cache, evicted)
            recalcStats()
        }
    }

    /// Clears all synced cached files. Pending uploads are untouched.
    public func clear() {
        persistTimer?.cancel()
        persistTimer = nil
        dirtyKeys.removeAll()
        let fm = FileManager.default
        for entry in entries.values {
            try? fm.removeItem(at: cacheDir.appending(path: entry.file))
        }
        entries.removeAll()
        try? store.clear(.cache)
        recalcStats()
    }

    // MARK: Persistence

    private func schedulePersist() {
        guard persistTimer == nil else { return }
        persistTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.persistTimer = nil
            self.persistNow()
        }
    }

    public func persistNow() {
        persistTimer?.cancel()
        persistTimer = nil
        guard !dirtyKeys.isEmpty else { return }
        let keys = dirtyKeys
        dirtyKeys.removeAll()
        let items = keys.compactMap { k in entries[k].map { (id: k, value: $0) } }
        try? store.put(.cache, items)
    }

    private func recalcStats() {
        entryCount = entries.count
        totalBytes = entries.values.reduce(0) { $0 + $1.size }
    }
}
