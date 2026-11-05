import Foundation
@testable import IvynoteKit

/// Answers requests from a table of `"METHOD path" -> (status, json)` and
/// records what was sent.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    enum Reply {
        case json(Int, String)
        case fail(URLError.Code)
    }

    private let lock = NSLock()
    private var routes: [String: Reply]
    private(set) var requests: [URLRequest] = []

    init(_ routes: [String: Reply] = [:]) { self.routes = routes }

    func set(_ key: String, _ reply: Reply) { lock.withLock { routes[key] = reply } }

    var sent: [URLRequest] { lock.withLock { requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path()
        let key = "\(request.httpMethod ?? "GET") \(path)"
        let reply: Reply? = lock.withLock {
            requests.append(request)
            return routes[key]
        }
        switch reply {
        case .json(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (Data(body.utf8), response)
        case .fail(let code):
            throw URLError(code)
        case nil:
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"error":"not_found","status":404}"#.utf8), response)
        }
    }
}

let userJSON = #"{"id":"u1234567","username":"ivy","email":"ivy@example.com","displayName":"Ivy","role":"admin","status":"active","createdAt":1,"updatedAt":1,"lastLoginAt":1,"lastSeenAt":1,"aiEnabled":true,"aiAvailable":true,"features":{}}"#
