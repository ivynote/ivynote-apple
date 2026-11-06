import Foundation

// The online features of a server library (guide 5.5, 5.6): attachments and
// the media library, history versions, public links and export. Unlike
// notes, none of this goes through sync: it needs the server.

/// `POST /attachments`.
public struct UploadResult: Decodable, Sendable {
    public var attachment: Attachment
    /// The same bytes were uploaded before; `attachment` is that file.
    public var duplicate: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attachment = try c.decode(Attachment.self, forKey: .attachment)
        duplicate = try c.value(.duplicate, false)
    }

    private enum CodingKeys: String, CodingKey { case attachment, duplicate }
}

/// What the media library shows (guide 11.6).
public enum MediaFilter: String, CaseIterable, Sendable {
    case all, image, video, audio, file, orphaned, trash

    public var label: String {
        switch self {
        case .all: L10n.s.filterAll
        case .image: L10n.s.filterImages
        case .video: L10n.s.filterVideo
        case .audio: L10n.s.filterAudio
        case .file: L10n.s.filterFiles
        case .orphaned: L10n.s.unreferenced
        case .trash: L10n.s.trash
        }
    }

    /// The same choice applied to synced metadata, for offline.
    public func matches(_ a: Attachment) -> Bool {
        switch self {
        case .trash: a.isTrashed
        case .all: !a.isTrashed
        case .orphaned: a.isOrphan
        default: !a.isTrashed && a.kind == rawValue
        }
    }
}

/// `GET /attachments`.
public struct MediaList: Decodable, Sendable {
    public struct Policy: Decodable, Equatable, Sendable {
        public var mode: String
        /// Days before an unreferenced file goes to the trash; 0 = never.
        public var orphanDays: Int
        public var trashDays: Int
        public var cdn: Bool

        public init(mode: String = "", orphanDays: Int = 0, trashDays: Int = 0, cdn: Bool = false) {
            self.mode = mode; self.orphanDays = orphanDays; self.trashDays = trashDays; self.cdn = cdn
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mode = try c.value(.mode, "")
            orphanDays = try c.value(.orphanDays, 0)
            trashDays = try c.value(.trashDays, 0)
            cdn = try c.value(.cdn, false)
        }

        private enum CodingKeys: String, CodingKey { case mode, orphanDays, trashDays, cdn }
    }

    public var items: [Attachment]
    /// Keys `all, image, video, audio, file, orphaned`.
    public var counts: [String: Int]
    public var policy: Policy

    public init(items: [Attachment], counts: [String: Int] = [:], policy: Policy = Policy()) {
        self.items = items; self.counts = counts; self.policy = policy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.value(.items, [])
        counts = try c.value(.counts, [:])
        policy = try c.decodeIfPresent(Policy.self, forKey: .policy) ?? Policy()
    }

    private enum CodingKeys: String, CodingKey { case items, counts, policy }
}

/// `GET /attachments/{id}`: the file and the notes that reference it.
public struct AttachmentDetail: Decodable, Sendable {
    public var attachment: Attachment
    /// Without bodies.
    public var notes: [Note]

    public init(attachment: Attachment, notes: [Note] = []) {
        self.attachment = attachment
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attachment = try c.decode(Attachment.self, forKey: .attachment)
        notes = try c.value(.notes, [])
    }

    private enum CodingKeys: String, CodingKey { case attachment, notes }
}

/// One saved version of a note (`GET /notes/{id}/history`).
public struct Revision: Decodable, Equatable, Identifiable, Sendable {
    public var rev: Int64
    public var title: String
    /// Only from `GET /notes/{id}/history/{rev}`.
    public var body: String?
    public var device: String
    public var size: Int64
    public var createdAt: Millis

    public var id: Int64 { rev }

    public init(rev: Int64, title: String, body: String? = nil, device: String = "", size: Int64 = 0, createdAt: Millis) {
        self.rev = rev; self.title = title; self.body = body; self.device = device; self.size = size; self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rev = try c.value(.rev, 0)
        title = try c.value(.title, "")
        body = try c.decodeIfPresent(String.self, forKey: .body)
        device = try c.value(.device, "")
        size = try c.value(.size, 0)
        createdAt = try c.value(.createdAt, 0)
    }

    private enum CodingKeys: String, CodingKey { case rev, title, body, device, size, createdAt }
}

/// A note's public link (`GET/PUT /notes/{id}/share`).
public struct Share: Decodable, Equatable, Identifiable, Sendable {
    public var id: String
    public var noteId: String
    /// 0 = never.
    public var expiresAt: Millis
    public var enabled: Bool
    public var views: Int
    public var lastViewedAt: Millis
    public var createdAt: Millis
    public var updatedAt: Millis
    public var hasPassword: Bool
    /// The access password, readable by the owner; empty for links set
    /// before passwords were kept.
    public var password: String
    public var noteTitle: String
    public var expired: Bool

    /// Shortest password the server accepts for a link.
    public static let minPassword = 6
    public static let maxPassword = 72

    public init(id: String, noteId: String, expiresAt: Millis = 0, enabled: Bool = true, views: Int = 0, hasPassword: Bool = true,
                password: String = "", noteTitle: String = "", expired: Bool = false) {
        self.id = id; self.noteId = noteId; self.expiresAt = expiresAt; self.enabled = enabled; self.views = views
        self.lastViewedAt = 0; self.createdAt = 0; self.updatedAt = 0; self.hasPassword = hasPassword
        self.password = password; self.noteTitle = noteTitle; self.expired = expired
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        noteId = try c.value(.noteId, "")
        expiresAt = try c.value(.expiresAt, 0)
        enabled = try c.value(.enabled, false)
        views = try c.value(.views, 0)
        lastViewedAt = try c.value(.lastViewedAt, 0)
        createdAt = try c.value(.createdAt, 0)
        updatedAt = try c.value(.updatedAt, 0)
        hasPassword = try c.value(.hasPassword, false)
        password = try c.value(.password, "")
        noteTitle = try c.value(.noteTitle, "")
        expired = try c.value(.expired, false)
    }

    private enum CodingKeys: String, CodingKey {
        case id, noteId, expiresAt, enabled, views, lastViewedAt, createdAt, updatedAt, hasPassword, password, noteTitle, expired
    }

    /// Reachable by anyone with the link and the password.
    public var isLive: Bool { enabled && hasPassword && !expired }

    /// Whether the server takes `p` as a link password (6–72 bytes).
    public static func validPassword(_ p: String) -> Bool {
        p.utf8.count >= minPassword && p.utf8.count <= maxPassword
    }

    /// Eight characters without look-alikes such as l/1 and O/0, as the web.
    public static func generatePassword() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<8).map { _ in alphabet.randomElement(using: &rng)! })
    }
}

extension APIClient {
    // MARK: Attachments (guide 5.6)

    /// Uploads a file as `multipart/form-data`, field `file`. The server
    /// dedups by content, so the same bytes give the same attachment.
    public func upload(_ data: Data, name: String, mime: String) async throws -> UploadResult {
        var req = try request("POST", "attachments", body: nil)
        let boundary = "ivy-\(newEntityID())\(newEntityID())"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.multipart(data, name: name, mime: mime, boundary: boundary)
        // Large files take a while; the session's idle timeout still applies.
        req.timeoutInterval = 600
        let body = try await perform(req)
        do {
            return try JSONDecoder().decode(UploadResult.self, from: body)
        } catch {
            throw APIError.invalidResponse
        }
    }

    static func multipart(_ data: Data, name: String, mime: String, boundary: String) -> Data {
        // As browsers do: the name in UTF-8, with quotes and line breaks escaped.
        let filename = name.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "%0D").replacingOccurrences(of: "\n", with: "%0A")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mime.isEmpty ? "application/octet-stream" : mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    public func media(_ filter: MediaFilter = .all, query: String = "") async throws -> MediaList {
        var items: [URLQueryItem] = []
        switch filter {
        case .all: break
        case .trash: items.append(URLQueryItem(name: "trashed", value: "1"))
        case .orphaned: items.append(URLQueryItem(name: "orphaned", value: "1"))
        default: items.append(URLQueryItem(name: "kind", value: filter.rawValue))
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { items.append(URLQueryItem(name: "q", value: q)) }
        return try await send("GET", "attachments" + Self.query(items))
    }

    public func attachment(_ id: String) async throws -> AttachmentDetail {
        try await send("GET", "attachments/\(Self.segment(id))")
    }

    public func renameAttachment(_ id: String, to name: String) async throws -> Attachment {
        struct Body: Encodable { var name: String }
        return try await send("PATCH", "attachments/\(Self.segment(id))", body: Body(name: name))
    }

    public func trashAttachment(_ id: String) async throws -> Attachment {
        try await send("POST", "attachments/\(Self.segment(id))/trash")
    }

    public func restoreAttachment(_ id: String) async throws -> Attachment {
        try await send("POST", "attachments/\(Self.segment(id))/restore")
    }

    /// Deletes a file for good; it must be in the trash first.
    public func purgeAttachment(_ id: String) async throws {
        let _: OK = try await send("DELETE", "attachments/\(Self.segment(id))")
    }

    /// Makes a public link (or returns the existing one).
    public func publishAttachment(_ id: String) async throws -> String {
        struct Link: Decodable { var url: String }
        let r: Link = try await send("POST", "attachments/\(Self.segment(id))/publish")
        return r.url
    }

    public func unpublishAttachment(_ id: String) async throws -> Attachment {
        try await send("DELETE", "attachments/\(Self.segment(id))/publish")
    }

    /// The request for an attachment's bytes, with the Bearer token in a
    /// header, never in the URL (guide 8.2).
    public func rawRequest(_ id: String, thumb: Bool = false) -> URLRequest {
        var url = server.apiBase.appending(path: "attachments/\(id)/raw")
        if thumb { url.append(queryItems: [URLQueryItem(name: "thumb", value: "1")]) }
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    // MARK: History (guide 5.5, 11.6)

    /// Newest first, at most 500.
    public func history(_ noteID: String) async throws -> [Revision] {
        try await send("GET", "notes/\(Self.segment(noteID))/history")
    }

    /// One version, with its body.
    public func revision(_ noteID: String, _ rev: Int64) async throws -> Revision {
        try await send("GET", "notes/\(Self.segment(noteID))/history/\(rev)")
    }

    // MARK: Sharing (guide 5.5)

    /// The note's link, or nil if it never had one.
    public func share(_ noteID: String) async throws -> Share? {
        try await send("GET", "notes/\(Self.segment(noteID))/share")
    }

    /// Sets the link. `enabled` and `expiresAt` are always written; a nil
    /// `password` keeps the current one, `""` removes it.
    public func setShare(_ noteID: String, enabled: Bool, password: String? = nil, expiresAt: Millis) async throws -> Share {
        struct Body: Encodable { var enabled: Bool; var password: String?; var expiresAt: Millis }
        return try await send("PUT", "notes/\(Self.segment(noteID))/share",
                              body: Body(enabled: enabled, password: password, expiresAt: expiresAt))
    }

    public func shares() async throws -> [Share] {
        try await send("GET", "shares")
    }

    public func deleteShare(_ id: String) async throws {
        let _: OK = try await send("DELETE", "shares/\(Self.segment(id))")
    }

    /// The page a link opens: `{server}/s/{id}`.
    public func shareURL(_ share: Share) -> URL {
        server.base.appending(path: "s/\(share.id)")
    }

    /// The note as Markdown. `public` publishes the attachments it uses and
    /// links them by their public addresses, for pasting elsewhere.
    public func exportNote(_ noteID: String, public isPublic: Bool) async throws -> String {
        let req = try request("GET", "notes/\(Self.segment(noteID))/export" + (isPublic ? "?public=1" : ""), body: nil)
        let data = try await perform(req)
        guard let text = String(data: data, encoding: .utf8) else { throw APIError.invalidResponse }
        return text
    }

    // MARK: Helpers

    private struct OK: Decodable {}

    /// Ids are `[A-Za-z0-9_-]`; anything else is escaped rather than trusted.
    static func segment(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? id
    }

    /// `?a=b&c=d`, encoded for the server (a `+` would read as a space).
    static func query(_ items: [URLQueryItem]) -> String {
        guard !items.isEmpty else { return "" }
        var c = URLComponents()
        c.queryItems = items
        return "?" + (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }
}
