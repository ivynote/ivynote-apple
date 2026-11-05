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
    private let session: URLSession
    private var running: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(account: StoredAccount?) {
        self.account = account
        root = Bundle.main.url(forResource: "Editor", withExtension: nil)
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        // Attachments never change under the same id: keep them for offline
        // reading and answer from the cache without asking again.
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "ivy-media")
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 512 << 20, directory: dir)
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
    }

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
        guard let account, id.wholeMatch(of: /[A-Za-z0-9_-]{8,64}/) != nil else {
            return respond(task, status: 404, headers: [:], data: Data())
        }
        var url = account.server.apiBase.appending(path: "attachments/\(id)/raw")
        if thumb { url.append(queryItems: [URLQueryItem(name: "thumb", value: "1")]) }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(account.token)", forHTTPHeaderField: "Authorization")
        // Videos and audio seek with byte ranges; pass them through.
        if let range = task.request.value(forHTTPHeaderField: "Range") {
            req.setValue(range, forHTTPHeaderField: "Range")
            req.cachePolicy = .reloadIgnoringLocalCacheData
        }
        let key = ObjectIdentifier(task)
        let session = session
        running[key] = Task { [weak self] in
            do {
                let (data, response) = try await session.data(for: req)
                guard let self, self.running.removeValue(forKey: key) != nil else { return }
                let http = response as? HTTPURLResponse
                editorLog.debug("res \(id, privacy: .public) -> \(http?.statusCode ?? 0) \(data.count) bytes")
                var headers: [String: String] = [:]
                for name in ["Content-Type", "Content-Range", "Accept-Ranges", "Content-Length"] {
                    if let v = http?.value(forHTTPHeaderField: name) { headers[name] = v }
                }
                self.respond(task, status: http?.statusCode ?? 200, headers: headers, data: data)
            } catch {
                guard let self, self.running.removeValue(forKey: key) != nil else { return }
                editorLog.error("res \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                self.fail(task, error)
            }
        }
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
