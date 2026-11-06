import Foundation

/// Timestamps are Unix milliseconds throughout.
public typealias Millis = Int64

public enum EntityType: String, Codable, Sendable {
    case note, folder, tag
}

/// Common shape of the entities merged by `SyncEngine.applyRemote`.
protocol SyncEntity: Codable, Sendable {
    var id: String { get }
    var seq: Int64 { get set }
    var deleted: Bool { get }
    var hlc: [String: String]? { get }
    /// Keeps a field the user changed locally but has not pushed yet.
    mutating func keepField(_ field: String, from local: Self)
    /// Applies a pushed field to an entity that has no local copy yet.
    mutating func applyField(_ field: String, _ value: JSONValue, now: Millis)
}

public struct Note: Codable, Equatable, Identifiable, Sendable, SyncEntity {
    public var id: String
    public var folderId: String
    public var title: String
    public var body: String
    public var tags: [String]
    public var pinned: Bool
    /// Content version: bumps when the title or body changes. 0 = never pushed.
    public var rev: Int64
    public var seq: Int64
    public var trashedAt: Millis
    public var deleted: Bool
    public var words: Int
    public var hlc: [String: String]?
    public var createdAt: Millis
    public var updatedAt: Millis

    public init(id: String, folderId: String = "", title: String = "", body: String = "", tags: [String] = [],
                pinned: Bool = false, rev: Int64 = 0, seq: Int64 = 0, trashedAt: Millis = 0, deleted: Bool = false,
                words: Int = 0, hlc: [String: String]? = nil, createdAt: Millis, updatedAt: Millis) {
        self.id = id; self.folderId = folderId; self.title = title; self.body = body; self.tags = tags
        self.pinned = pinned; self.rev = rev; self.seq = seq; self.trashedAt = trashedAt; self.deleted = deleted
        self.words = words; self.hlc = hlc; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        folderId = try c.value(.folderId, "")
        title = try c.value(.title, "")
        body = try c.value(.body, "")
        tags = try c.value(.tags, [])
        pinned = try c.value(.pinned, false)
        rev = try c.value(.rev, 0)
        seq = try c.value(.seq, 0)
        trashedAt = try c.value(.trashedAt, 0)
        deleted = try c.value(.deleted, false)
        words = try c.value(.words, 0)
        hlc = try c.decodeIfPresent([String: String].self, forKey: .hlc)
        createdAt = try c.value(.createdAt, 0)
        updatedAt = try c.value(.updatedAt, 0)
    }

    public var isTrashed: Bool { trashedAt > 0 }

    mutating func keepField(_ field: String, from local: Note) {
        switch field {
        case "title": title = local.title
        case "body": body = local.body
        case "folderId": folderId = local.folderId
        case "tags": tags = local.tags
        case "pinned": pinned = local.pinned
        case "trashed": trashedAt = local.trashedAt
        default: break
        }
    }

    mutating func applyField(_ field: String, _ value: JSONValue, now: Millis) {
        switch field {
        case "title": title = value.stringValue ?? title
        case "body": body = value.stringValue ?? body
        case "folderId": folderId = value.stringValue ?? folderId
        case "tags": tags = value.stringArray ?? tags
        case "pinned": pinned = value.boolValue ?? pinned
        case "trashed": trashedAt = value.boolValue == true ? (trashedAt > 0 ? trashedAt : now) : 0
        default: break
        }
    }
}

public struct Folder: Codable, Equatable, Identifiable, Sendable, SyncEntity {
    public var id: String
    public var parentId: String
    public var name: String
    public var sort: Double
    public var seq: Int64
    public var deleted: Bool
    public var hlc: [String: String]?
    public var createdAt: Millis
    public var updatedAt: Millis

    public init(id: String, parentId: String = "", name: String, sort: Double = 0, seq: Int64 = 0,
                deleted: Bool = false, createdAt: Millis, updatedAt: Millis) {
        self.id = id; self.parentId = parentId; self.name = name; self.sort = sort; self.seq = seq
        self.deleted = deleted; self.hlc = nil; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        parentId = try c.value(.parentId, "")
        name = try c.value(.name, "")
        sort = try c.value(.sort, 0)
        seq = try c.value(.seq, 0)
        deleted = try c.value(.deleted, false)
        hlc = try c.decodeIfPresent([String: String].self, forKey: .hlc)
        createdAt = try c.value(.createdAt, 0)
        updatedAt = try c.value(.updatedAt, 0)
    }

    mutating func keepField(_ field: String, from local: Folder) {
        switch field {
        case "name": name = local.name
        case "parentId": parentId = local.parentId
        case "sort": sort = local.sort
        default: break
        }
    }

    mutating func applyField(_ field: String, _ value: JSONValue, now: Millis) {
        switch field {
        case "name": name = value.stringValue ?? name
        case "parentId": parentId = value.stringValue ?? parentId
        case "sort": sort = value.doubleValue ?? sort
        default: break
        }
    }
}

public struct Tag: Codable, Equatable, Identifiable, Sendable, SyncEntity {
    public var id: String
    public var name: String
    public var color: String
    public var seq: Int64
    public var deleted: Bool
    public var hlc: [String: String]?
    public var createdAt: Millis
    public var updatedAt: Millis

    public init(id: String, name: String, color: String = "", seq: Int64 = 0, deleted: Bool = false, createdAt: Millis, updatedAt: Millis) {
        self.id = id; self.name = name; self.color = color; self.seq = seq; self.deleted = deleted
        self.hlc = nil; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.value(.name, "")
        color = try c.value(.color, "")
        seq = try c.value(.seq, 0)
        deleted = try c.value(.deleted, false)
        hlc = try c.decodeIfPresent([String: String].self, forKey: .hlc)
        createdAt = try c.value(.createdAt, 0)
        updatedAt = try c.value(.updatedAt, 0)
    }

    mutating func keepField(_ field: String, from local: Tag) {
        switch field {
        case "name": name = local.name
        case "color": color = local.color
        default: break
        }
    }

    mutating func applyField(_ field: String, _ value: JSONValue, now: Millis) {
        switch field {
        case "name": name = value.stringValue ?? name
        case "color": color = value.stringValue ?? color
        default: break
        }
    }
}

public struct Attachment: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case image, video, audio, file }

    public var id: String
    public var name: String
    public var mime: String
    public var kind: String
    /// Plain bytes.
    public var size: Int64
    public var width: Int?
    public var height: Int?
    /// Plain SHA-256, hex.
    public var sha256: String
    /// `local` or `s3`.
    public var storage: String
    public var hasThumb: Bool
    /// Notes that reference it.
    public var refs: Int
    public var orphanSince: Millis
    public var trashedAt: Millis
    /// `manual` or `orphan`.
    public var trashReason: String
    public var `public`: Bool
    /// Set only for a CDN copy; other public links come from `publish`.
    public var publicUrl: String
    public var seq: Int64
    public var deleted: Bool
    public var createdAt: Millis
    public var updatedAt: Millis

    public init(id: String, name: String, mime: String, kind: String? = nil, size: Int64, width: Int? = nil, height: Int? = nil,
                sha256: String = "", storage: String = "", hasThumb: Bool = false, refs: Int = 0, orphanSince: Millis = 0,
                trashedAt: Millis = 0, trashReason: String = "", public isPublic: Bool = false, publicUrl: String = "", seq: Int64 = 0,
                deleted: Bool = false, createdAt: Millis, updatedAt: Millis) {
        self.id = id; self.name = name; self.mime = mime; self.kind = kind ?? Self.kind(of: mime).rawValue
        self.size = size; self.width = width; self.height = height; self.sha256 = sha256; self.storage = storage
        self.hasThumb = hasThumb; self.refs = refs; self.orphanSince = orphanSince; self.trashedAt = trashedAt
        self.trashReason = trashReason; self.public = isPublic; self.publicUrl = publicUrl; self.seq = seq
        self.deleted = deleted; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.value(.name, "")
        mime = try c.value(.mime, "")
        kind = try c.value(.kind, "file")
        size = try c.value(.size, 0)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        sha256 = try c.value(.sha256, "")
        storage = try c.value(.storage, "")
        hasThumb = try c.value(.hasThumb, false)
        refs = try c.value(.refs, 0)
        orphanSince = try c.value(.orphanSince, 0)
        trashedAt = try c.value(.trashedAt, 0)
        trashReason = try c.value(.trashReason, "")
        `public` = try c.value(.public, false)
        publicUrl = try c.value(.publicUrl, "")
        seq = try c.value(.seq, 0)
        deleted = try c.value(.deleted, false)
        createdAt = try c.value(.createdAt, 0)
        updatedAt = try c.value(.updatedAt, 0)
    }

    public var isTrashed: Bool { trashedAt > 0 }
    public var isOrphan: Bool { refs == 0 && !isTrashed }

    /// The web client's `kindOf`: what the server would call this MIME type.
    public static func kind(of mime: String) -> Kind {
        let m = mime.lowercased()
        if m.hasPrefix("image/") { return .image }
        if m.hasPrefix("video/") { return .video }
        if m.hasPrefix("audio/") { return .audio }
        return .file
    }

    /// The Markdown that embeds it (guide 7.1): a link for plain files, an
    /// embed for media; `[` and `]` are dropped from the name.
    public static func markdown(id: String, name: String, kind: String) -> String {
        let label = name.filter { $0 != "[" && $0 != "]" }
        return "\(kind == Kind.file.rawValue ? "" : "!")[\(label)](ivy://res/\(id))"
    }

    public var markdown: String { Self.markdown(id: id, name: name, kind: kind) }
}

/// A file added while the server could not be reached, kept under a `local-`
/// id until `SyncEngine.flushUploads` sends it (guide 7.2).
public struct PendingUpload: Codable, Equatable, Identifiable, Sendable {
    public static let prefix = "local-"

    public var id: String
    public var name: String
    public var mime: String
    /// The copy's file name in the library's uploads folder.
    public var file: String
    public var size: Int64
    public var createdAt: Millis
    /// Why the server refused it; not tried again until the app restarts.
    public var failed: String?

    public var kind: String { Attachment.kind(of: mime).rawValue }
}

// MARK: Wire format

public struct Change: Codable, Equatable, Sendable {
    public enum Op: String, Codable, Sendable { case upsert, delete }

    public var type: EntityType
    public var id: String
    public var op: Op
    public var fields: [String: JSONValue]?
    public var hlc: String
    public var baseRev: Int64?
    public var device: String?
}

public struct ChangeResult: Codable, Equatable, Sendable {
    public var type: EntityType
    public var id: String
    public var ok: Bool
    public var error: String?
    public var seq: Int64?
    public var rev: Int64?
    public var merged: Bool?
    public var body: String?
    public var conflictCopy: String?

    public init(type: EntityType, id: String, ok: Bool, error: String? = nil, seq: Int64? = nil, rev: Int64? = nil,
                merged: Bool? = nil, body: String? = nil, conflictCopy: String? = nil) {
        self.type = type; self.id = id; self.ok = ok; self.error = error; self.seq = seq; self.rev = rev
        self.merged = merged; self.body = body; self.conflictCopy = conflictCopy
    }
}

public struct PushResponse: Codable, Sendable {
    public var results: [ChangeResult]
    public var seq: Int64
}

public struct PullResponse: Codable, Sendable {
    public var seq: Int64
    public var folders: [Folder]
    public var tags: [Tag]
    public var notes: [Note]
    public var attachments: [Attachment]

    public init(seq: Int64, folders: [Folder] = [], tags: [Tag] = [], notes: [Note] = [], attachments: [Attachment] = []) {
        self.seq = seq; self.folders = folders; self.tags = tags; self.notes = notes; self.attachments = attachments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.value(.seq, 0)
        folders = try c.value(.folders, [])
        tags = try c.value(.tags, [])
        notes = try c.value(.notes, [])
        attachments = try c.value(.attachments, [])
    }
}

/// A local change waiting to be pushed. One per entity (`key = type:id`).
struct OutboxEntry: Codable, Equatable, Sendable {
    var key: String
    var type: EntityType
    var id: String
    var op: Change.Op
    var fields: [String: JSONValue]
    var hlc: String
    var baseRev: Int64?
    var device: String
    /// Bumped on every local edit, to tell whether it changed during a push.
    var version: Int
    /// The HLC of the first edit: pushes go out in the order entities were
    /// touched, so a new folder reaches the server before notes moved into it.
    var order: String
    /// Why the server refused it. Not pushed again until edited or restarted.
    var blocked: String?

    var change: Change {
        Change(type: type, id: id, op: op,
               fields: op == .upsert ? fields : nil,
               hlc: hlc,
               baseRev: fields["body"] != nil ? baseRev : nil,
               device: device)
    }
}

/// 16 random `[a-z0-9]`, from the system CSPRNG.
public func newEntityID() -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    var rng = SystemRandomNumberGenerator()
    return String((0..<16).map { _ in alphabet.randomElement(using: &rng)! })
}
