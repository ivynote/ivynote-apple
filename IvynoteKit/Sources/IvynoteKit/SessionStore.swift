import Foundation
import Observation

/// Who is signed in, to which server, and whether the server is reachable.
///
/// Follows the guide's session rules: the cached account opens the app
/// immediately; `GET /me` refreshes it in the background; only 401/403 end
/// the session, while network errors and 5xx just mark the app offline.
@MainActor
@Observable
public final class SessionStore {
    public enum State: Equatable {
        case loading
        case signedOut
        case signedIn(StoredAccount)
    }

    public private(set) var state: State = .loading
    /// The last `/me` check could not reach the server.
    public private(set) var isOffline = false
    /// Shown on the sign-in screen after the server ended the session.
    public private(set) var notice: String?
    /// The server of the last account, to prefill the connect screen.
    public private(set) var lastServer: ServerAddress?

    private let store: CredentialStore
    private let transport: HTTPTransport
    private let defaults: UserDefaults

    public init(store: CredentialStore = KeychainCredentialStore(),
                transport: HTTPTransport = URLSessionTransport(),
                defaults: UserDefaults = .standard) {
        self.store = store
        self.transport = transport
        self.defaults = defaults
        if let s = defaults.string(forKey: Self.lastServerKey) {
            lastServer = try? ServerAddress(parsing: s)
        }
    }

    public var account: StoredAccount? {
        if case .signedIn(let a) = state { a } else { nil }
    }

    public func client(for server: ServerAddress) -> APIClient {
        APIClient(server: server, transport: transport)
    }

    /// The API client for the signed-in account.
    public var api: APIClient? {
        account.map { APIClient(server: $0.server, token: $0.token, transport: transport) }
    }

    public func restore() async {
        let saved: StoredAccount?
        do { saved = try store.load() } catch { saved = nil }
        guard let saved else {
            state = .signedOut
            return
        }
        state = .signedIn(saved)
        await refresh()
    }

    /// Re-checks the session with `GET /me`.
    public func refresh() async {
        guard let current = account, let api else { return }
        do {
            let user = try await api.me()
            isOffline = false
            guard account?.token == current.token else { return } // signed out meanwhile
            var updated = current
            updated.user = user
            if updated != current {
                try? store.save(updated)
                state = .signedIn(updated)
            }
        } catch let error as APIError where error.endsSession {
            expire(error)
        } catch {
            isOffline = true
        }
    }

    public func signIn(server: ServerAddress, token: String, user: User) throws {
        let account = StoredAccount(server: server, token: token, user: user)
        try store.save(account)
        remember(server)
        notice = nil
        isOffline = false
        state = .signedIn(account)
    }

    /// Revokes this device's token (best effort) and forgets the account.
    /// Once the local database exists this must sync first, then clear it.
    public func signOut() async {
        if let api { try? await api.logout() }
        try? store.clear()
        isOffline = false
        state = .signedOut
    }

    private func expire(_ error: APIError) {
        // The token is no longer valid. Local notes and the outbox must be
        // kept (guide 5.1): signing in again resumes syncing them.
        try? store.clear()
        notice = error.status == 403
            ? (error.errorDescription ?? "账户不可用")
            : "登录已过期，请重新登录"
        isOffline = false
        state = .signedOut
    }

    private func remember(_ server: ServerAddress) {
        lastServer = server
        defaults.set(server.description, forKey: Self.lastServerKey)
    }

    static let lastServerKey = "ivy.lastServer"
}
