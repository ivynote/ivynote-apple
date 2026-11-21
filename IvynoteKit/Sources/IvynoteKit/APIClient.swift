import Foundation

/// Sends one HTTP request. Swapped for a stub in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Sends a potentially large attachment upload using a session configured
    /// to wait for connectivity with generous timeouts.
    func sendUpload(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension HTTPTransport {
    public func sendUpload(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await send(request)
    }
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    let uploadSession: URLSession

    public init(session: URLSession, uploadSession: URLSession? = nil) {
        self.session = session
        self.uploadSession = uploadSession ?? session
    }

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

        let upConfig = URLSessionConfiguration.ephemeral
        upConfig.httpCookieStorage = nil
        upConfig.httpShouldSetCookies = false
        upConfig.httpCookieAcceptPolicy = .never
        upConfig.urlCache = nil
        upConfig.timeoutIntervalForRequest = 120
        upConfig.timeoutIntervalForResource = 600
        upConfig.waitsForConnectivity = true
        uploadSession = URLSession(configuration: upConfig)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return (data, http)
    }

    public func sendUpload(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await uploadSession.data(for: request)
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

    /// `language`: the interface language at sign-up; it becomes the account's.
    public func register(username: String, password: String, email: String, displayName: String,
                         language: String = L10n.language.rawValue) async throws -> (token: String, user: User) {
        struct Body: Encodable { var username: String; var password: String; var email: String?; var displayName: String?; var language: String? }
        let body = Body(username: username, password: password,
                        email: email.isEmpty ? nil : email,
                        displayName: displayName.isEmpty ? nil : displayName,
                        language: language.isEmpty ? nil : language)
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

    /// Sets the account's interface language; "" clears it (follow the device).
    public func setLanguage(_ language: String) async throws -> User {
        struct Body: Encodable { var language: String }
        return try await send("PATCH", "me", body: Body(language: language))
    }

    // MARK: Plumbing

    private struct Empty: Encodable {}
    private struct ErrorBody: Decodable { var error: String? }

    func request(_ method: String, _ path: String, body: (any Encodable)?) throws -> URLRequest {
        let parts = path.split(separator: "?", maxSplits: 1)
        var url = server.apiBase.appending(path: String(parts[0]))
        if parts.count == 2, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.percentEncodedQuery = String(parts[1])
            url = c.url ?? url
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // The interface language, so server messages can match it.
        req.setValue(L10n.language.rawValue, forHTTPHeaderField: "Accept-Language")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        return req
    }

    func send<T: Decodable>(_ method: String, _ path: String, body: (any Encodable)? = nil) async throws -> T {
        let data = try await perform(try request(method, path, body: body))
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    /// Sends a request and returns the body of a 2xx answer; maps every
    /// failure to an `APIError`.
    func perform(_ req: URLRequest) async throws -> Data {
        try await performRequest(req, via: transport.send)
    }

    func performUpload(_ req: URLRequest) async throws -> Data {
        try await performRequest(req, via: transport.sendUpload)
    }

    private func performRequest(_ req: URLRequest, via sender: (URLRequest) async throws -> (Data, HTTPURLResponse)) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await sender(req)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.unreachable(error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? ""
            throw APIError.server(status: response.statusCode, message: message)
        }
        return data
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
