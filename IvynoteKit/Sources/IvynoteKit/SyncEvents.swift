import Foundation

/// `GET /sync/events`: server-sent events announcing the latest `seq`
/// (guide 6.9). Only a hint to pull; a lost event does no harm.
public struct SyncEvents: Sendable {
    let api: APIClient
    let session: URLSession

    public init(api: APIClient) {
        self.api = api
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        // The server sends a comment every 25 s; anything quieter is dead.
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = .infinity
        session = URLSession(configuration: config)
    }

    /// Yields each announced `seq` until the connection drops.
    public func stream() -> AsyncThrowingStream<Int64, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = try api.request("GET", "sync/events", body: nil)
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
                    guard http.statusCode == 200 else { throw APIError.server(status: http.statusCode, message: "") }
                    var event = ""
                    for try await line in bytes.lines {
                        if let seq = Self.parse(line, event: &event) { continuation.yield(seq) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Feeds one line; returns a `seq` when a `seq` event's data arrives.
    static func parse(_ line: String, event: inout String) -> Int64? {
        if line.isEmpty { event = ""; return nil }
        if line.hasPrefix(":") { return nil }
        let (field, value) = split(line)
        switch field {
        case "event":
            event = value
        case "data":
            defer { event = "" }
            if event == "seq" || event.isEmpty { return Int64(value.trimmingCharacters(in: .whitespaces)) }
        default:
            break
        }
        return nil
    }

    private static func split(_ line: String) -> (String, String) {
        guard let i = line.firstIndex(of: ":") else { return (line, "") }
        var value = line[line.index(after: i)...]
        if value.hasPrefix(" ") { value = value.dropFirst() }
        return (String(line[..<i]), String(value))
    }
}
