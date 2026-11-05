import Foundation

/// Sends one HTTP request. Swapped for a stub in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init() {
        // Native clients authenticate with the Bearer token only; no cookies,
        // no shared cache that could keep note content on disk.
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return (data, http)
    }
}

/// The Ivynote REST API (`{server}/api/v1`). See the client development guide
/// in the ivynote repository, chapter 5.
public struct APIClient: Sendable {
    public let server: ServerAddress
    public let token: String?
    let transport: HTTPTransport

    public init(server: ServerAddress, token: String? = nil, transport: HTTPTransport = URLSessionTransport()) {
        self.server = server
        self.token = token
        self.transport = transport
    }

    public func authorized(_ token: String?) -> APIClient {
        APIClient(server: server, token: token, transport: transport)
    }

    // MARK: Public

    public func health() async throws -> Health {
        try await send("GET", "health")
    }

    public func info() async throws -> ServerInfo {
        try await send("GET", "info")
    }

    /// Checks that the address is an Ivynote server and returns what it allows.
    public func probe() async throws -> ServerInfo {
        let health = try await self.health()
        guard health.ok else { throw APIError.invalidResponse }
        return try await info()
    }

    public func login(identity: String, password: String) async throws -> (token: String, user: User) {
        struct Body: Encodable { var identity: String; var password: String }
        let r: AuthResponse = try await send("POST", "auth/login", body: Body(identity: identity, password: password))
        return (r.token, r.user)
    }

    public func register(username: String, password: String, email: String, displayName: String) async throws -> (token: String, user: User) {
        struct Body: Encodable { var username: String; var password: String; var email: String?; var displayName: String? }
        let body = Body(username: username, password: password,
                        email: email.isEmpty ? nil : email,
                        displayName: displayName.isEmpty ? nil : displayName)
        let r: AuthResponse = try await send("POST", "auth/register", body: body)
        return (r.token, r.user)
    }

    /// Ends only this device's session.
    public func logout() async throws {
        struct OK: Decodable {}
        let _: OK = try await send("POST", "auth/logout")
    }

    // MARK: Account

    public func me() async throws -> User {
        try await send("GET", "me")
    }

    // MARK: Plumbing

    private struct Empty: Encodable {}
    private struct ErrorBody: Decodable { var error: String? }

    func request(_ method: String, _ path: String, body: (any Encodable)?) throws -> URLRequest {
        var req = URLRequest(url: server.apiBase.appending(path: path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        return req
    }

    func send<T: Decodable>(_ method: String, _ path: String, body: (any Encodable)? = nil) async throws -> T {
        let req = try request(method, path, body: body)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(req)
        } catch let error as APIError {
            throw error
        } catch let error as URLError {
            throw APIError.unreachable(error.localizedDescription)
        } catch {
            throw APIError.unreachable(error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? ""
            throw APIError.server(status: response.statusCode, message: message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        #if os(macOS)
        return "Ivynote-macOS/\(version)"
        #else
        return "Ivynote-iOS/\(version)"
        #endif
    }()
}
