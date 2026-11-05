import Foundation
import Testing
@testable import IvynoteKit

@MainActor
@Suite struct SessionStoreTests {
    let server = try! ServerAddress(parsing: "https://notes.example.com")
    let defaults: UserDefaults = {
        let d = UserDefaults(suiteName: "ivy.tests.\(UUID().uuidString)")!
        return d
    }()

    func cached(name: String = "Old") -> StoredAccount {
        StoredAccount(server: server, token: "tok", user: User(id: "u1234567", username: "ivy", displayName: name))
    }

    @Test func noAccountSignsOut() async {
        let s = SessionStore(store: InMemoryCredentialStore(), transport: StubTransport(), defaults: defaults)
        await s.restore()
        #expect(s.state == .signedOut)
    }

    @Test func refreshUpdatesCachedUser() async throws {
        let store = InMemoryCredentialStore(cached())
        let s = SessionStore(store: store, transport: StubTransport(["GET /api/v1/me": .json(200, userJSON)]), defaults: defaults)
        await s.restore()
        #expect(s.account?.user.name == "Ivy")
        #expect(try store.load()?.user.name == "Ivy")
        #expect(!s.isOffline)
    }

    @Test func offlineKeepsCachedAccount() async {
        let s = SessionStore(store: InMemoryCredentialStore(cached()), transport: StubTransport(["GET /api/v1/me": .fail(.timedOut)]), defaults: defaults)
        await s.restore()
        #expect(s.account?.user.name == "Old")
        #expect(s.isOffline)
    }

    @Test func serverErrorKeepsCachedAccount() async {
        let s = SessionStore(store: InMemoryCredentialStore(cached()), transport: StubTransport(["GET /api/v1/me": .json(503, "")]), defaults: defaults)
        await s.restore()
        #expect(s.account != nil)
        #expect(s.isOffline)
    }

    @Test(arguments: [401, 403])
    func unauthorizedEndsSession(status: Int) async throws {
        let store = InMemoryCredentialStore(cached())
        let s = SessionStore(store: store, transport: StubTransport(["GET /api/v1/me": .json(status, #"{"error":"account disabled"}"#)]), defaults: defaults)
        await s.restore()
        #expect(s.state == .signedOut)
        #expect(s.notice != nil)
        #expect(try store.load() == nil)
    }

    @Test func signInPersistsAndRemembersServer() throws {
        let store = InMemoryCredentialStore()
        let s = SessionStore(store: store, transport: StubTransport(), defaults: defaults)
        try s.signIn(server: server, token: "new", user: User(id: "u1234567", username: "ivy"))
        #expect(try store.load()?.token == "new")
        #expect(SessionStore(store: store, transport: StubTransport(), defaults: defaults).lastServer == server)
    }

    @Test func signOutRevokesAndClears() async throws {
        let t = StubTransport(["POST /api/v1/auth/logout": .json(200, #"{"ok":true}"#)])
        let store = InMemoryCredentialStore(cached())
        let s = SessionStore(store: store, transport: t, defaults: defaults)
        await s.restore()
        await s.signOut()
        #expect(s.state == .signedOut)
        #expect(try store.load() == nil)
        #expect(t.sent.contains { $0.url!.path() == "/api/v1/auth/logout" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer tok" })
    }

    @Test func signOutWorksOffline() async throws {
        let store = InMemoryCredentialStore(cached())
        let s = SessionStore(store: store, transport: StubTransport(["POST /api/v1/auth/logout": .fail(.notConnectedToInternet)]), defaults: defaults)
        await s.restore()
        await s.signOut()
        #expect(s.state == .signedOut)
        #expect(try store.load() == nil)
    }
}

@Suite(.serialized) struct KeychainTests {
    @Test func roundTrip() throws {
        let store = KeychainCredentialStore(service: "app.ivynote.tests", account: UUID().uuidString)
        defer { try? store.clear() }
        #expect(try store.load() == nil)
        let a = StoredAccount(server: try ServerAddress(parsing: "notes.example.com"), token: "t1", user: User(id: "u1234567", username: "ivy"))
        try store.save(a)
        #expect(try store.load() == a)
        var b = a
        b.token = "t2"
        try store.save(b)
        #expect(try store.load()?.token == "t2")
        try store.clear()
        #expect(try store.load() == nil)
    }
}
