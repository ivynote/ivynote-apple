import Foundation

/// What the sync engine needs from the server (guide 5.4).
public protocol SyncTransport: Sendable {
    func snapshot() async throws -> PullResponse
    func pull(since: Int64) async throws -> PullResponse
    func push(_ changes: [Change]) async throws -> PushResponse
    /// `POST /attachments`; the server dedups by content.
    func uploadFile(_ data: Data, name: String, mime: String) async throws -> Attachment
}

extension SyncTransport {
    public func uploadFile(_ data: Data, name: String, mime: String) async throws -> Attachment {
        throw APIError.server(status: 501, message: "uploads not supported")
    }
}

extension APIClient: SyncTransport {
    public func snapshot() async throws -> PullResponse {
        try await send("GET", "sync/snapshot")
    }

    public func pull(since: Int64) async throws -> PullResponse {
        try await send("GET", "sync/pull?since=\(since)")
    }

    public func push(_ changes: [Change]) async throws -> PushResponse {
        struct Body: Encodable { var changes: [Change] }
        return try await send("POST", "sync/push", body: Body(changes: changes))
    }

    public func uploadFile(_ data: Data, name: String, mime: String) async throws -> Attachment {
        try await upload(data, name: name, mime: mime).attachment
    }
}
