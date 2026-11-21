import Foundation
import IvynoteKit
import OSLog
import WebKit

let editorLog = Logger(subsystem: "app.ivynote", category: "editor")

/// Serves the editor page under `ivyapp://editor/` from the app bundle, and
/// attachments under `ivyapp://editor/res/<id>` from the server with the
/// account's token. One origin for both, so the page needs no CORS and the
/// token never appears in a URL (guide 8.2).
@MainActor
final class EditorSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "ivyapp"
    static let pageURL = URL(string: "\(scheme)://editor/index.html")!

    private let root: URL?
    /// Nil in a local library, which has no server to fetch attachments from.
    private let account: StoredAccount?
    /// Local-first lookup: checks pending uploads and synced local cache.
    private let localLookup: @MainActor (String, Bool) -> (url: URL, mime: String)?
    /// Resolves any `local-` alias to its canonical server ID.
    private let canonicalID: @MainActor (String) -> String
    /// Persists downloaded bytes into the library's local attachment cache.
    private let cacheStore: @MainActor (String, Bool, Data, String) -> Void
    private let session: URLSession
    private var running: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(account: StoredAccount?, engine: SyncEngine?) {
        self.account = account
        self.localLookup = { [weak engine] id, thumb in engine?.localAttachment(id, thumb: thumb) }
        self.canonicalID = { [weak engine] id in engine?.attachmentCache.canonicalID(id) ?? id }
        self.cacheStore = { [weak engine] id, thumb, data, mime in
            _ = engine?.attachmentCache.store(id: id, thumb: thumb, data: data, mime: mime)
        }
        root = Bundle.main.url(forResource: "Editor", withExtension: nil)
        session = Self.mediaSession
    }

    /// Network session for uncached attachments: disk caching is owned by
    /// `AttachmentStore` so limits, access-based eviction and sign-out cleanup
    /// stay under one roof without storing duplicate copies.
    static let mediaSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return fail(task, URLError(.badURL)) }
        let path = url.path()
        editorLog.debug("request \(path, privacy: .public)")
        if path.hasPrefix("/res/") {
            let id = String(path.dropFirst("/res/".count))
            let thumb = url.query()?.contains("thumb=1") == true
            fetchAttachment(id: id, thumb: thumb, task: task)
        } else {
            serveFile(path == "/" ? "/index.html" : path, task: task)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        running.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }

    private func serveFile(_ path: String, task: any WKURLSchemeTask) {
        guard let root else { return fail(task, URLError(.fileDoesNotExist)) }
        let file = root.appending(path: String(path.dropFirst())).standardizedFileURL
        // Nothing outside the editor folder.
        guard file.path.hasPrefix(root.standardizedFileURL.path + "/"),
              let data = try? Data(contentsOf: file) else {
            return respond(task, status: 404, headers: [:], data: Data())
        }
        respond(task, status: 200, headers: ["Content-Type": Self.mime(file.pathExtension), "Cache-Control": "no-cache"], data: data)
    }

    private func fetchAttachment(id: String, thumb: Bool, task: any WKURLSchemeTask) {
        // Local-first: pending upload (`local-*`), promoted alias, or cached synced file.
        if let local = localLookup(id, thumb), let data = try? Data(contentsOf: local.url) {
            return respondLocal(task, data: data, mime: local.mime)
        }
        let resolvedID = canonicalID(id)
        if resolvedID.hasPrefix(PendingUpload.prefix) {
            return respond(task, status: 404, headers: [:], data: Data())
        }
        guard let account, resolvedID.wholeMatch(of: /[A-Za-z0-9_-]{8,64}/) != nil else {
            return respond(task, status: 404, headers: [:], data: Data())
        }
        var url = account.server.apiBase.appending(path: "attachments/\(resolvedID)/raw")
        if thumb { url.append(queryItems: [URLQueryItem(name: "thumb", value: "1")]) }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(account.token)", forHTTPHeaderField: "Authorization")
        // Videos and audio seek with byte ranges; pass them through without caching partials.
        let range = task.request.value(forHTTPHeaderField: "Range")
        if let range {
            req.setValue(range, forHTTPHeaderField: "Range")
        }
        let key = ObjectIdentifier(task)
        let session = session
        running[key] = Task { [weak self] in
            do {
                let (data, response) = try await session.data(for: req)
                guard let self, self.running.removeValue(forKey: key) != nil else { return }
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 200
                editorLog.debug("res \(resolvedID, privacy: .public) -> \(status) \(data.count) bytes")
                var headers: [String: String] = [:]
                for name in ["Content-Type", "Content-Range", "Accept-Ranges", "Content-Length"] {
                    if let v = http?.value(forHTTPHeaderField: name) { headers[name] = v }
                }
                if status == 200 && range == nil {
                    let mime = headers["Content-Type"] ?? "application/octet-stream"
                    self.cacheStore(resolvedID, thumb, data, mime)
                }
                self.respond(task, status: status, headers: headers, data: data)
            } catch {
                guard let self, self.running.removeValue(forKey: key) != nil else { return }
                editorLog.error("res \(resolvedID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                self.fail(task, error)
            }
        }
    }

    /// A local file, honouring a byte range: video and audio seek with them.
    private func respondLocal(_ task: any WKURLSchemeTask, data: Data, mime: String) {
        var headers = ["Content-Type": mime, "Accept-Ranges": "bytes"]
        if let range = task.request.value(forHTTPHeaderField: "Range"),
           let m = range.wholeMatch(of: /bytes=(\d*)-(\d*)/), !data.isEmpty {
            let count = data.count
            var start = Int(m.1) ?? 0
            var end = Int(m.2) ?? (count - 1)
            if m.1.isEmpty, let suffix = Int(m.2) { start = max(0, count - suffix); end = count - 1 }
            end = min(end, count - 1)
            guard start <= end else {
                return respond(task, status: 416, headers: ["Content-Range": "bytes */\(count)"], data: Data())
            }
            headers["Content-Range"] = "bytes \(start)-\(end)/\(count)"
            headers["Content-Length"] = "\(end - start + 1)"
            return respond(task, status: 206, headers: headers, data: data.subdata(in: start..<(end + 1)))
        }
        headers["Content-Length"] = "\(data.count)"
        respond(task, status: 200, headers: headers, data: data)
    }

    private func respond(_ task: any WKURLSchemeTask, status: Int, headers: [String: String], data: Data) {
        guard let url = task.request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: any WKURLSchemeTask, _ error: Error) {
        task.didFailWithError(error)
    }

    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "woff2": "font/woff2"
        default: "application/octet-stream"
        }
    }
}
