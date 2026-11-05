import Foundation
import Testing
@testable import IvynoteKit

/// Runs against a real Ivynote server when `IVY_TEST_SERVER` is set, e.g.
/// `IVY_TEST_SERVER=http://127.0.0.1:18080 swift test`. Registers a throwaway
/// account, so point it at a disposable server only.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["IVY_TEST_SERVER"] != nil))
struct LiveServerTests {
    @Test func accountLifecycle() async throws {
        let server = try ServerAddress(parsing: ProcessInfo.processInfo.environment["IVY_TEST_SERVER"]!)
        let api = APIClient(server: server)

        let info = try await api.probe()
        #expect(!info.version.isEmpty)

        let username = "apple\(Int.random(in: 1000...9999))"
        let password = "test-password-1"
        let registered: (token: String, user: User)
        if info.canRegister {
            registered = try await api.register(username: username, password: password, email: "", displayName: "Apple Test")
        } else {
            Issue.record("server does not allow registration; use an empty server")
            return
        }
        #expect(registered.user.username == username)

        let me = try await api.authorized(registered.token).me()
        #expect(me.id == registered.user.id)

        try await api.authorized(registered.token).logout()
        do {
            _ = try await api.authorized(registered.token).me()
            Issue.record("revoked token still works")
        } catch let e as APIError {
            #expect(e.endsSession)
        }

        do {
            _ = try await api.login(identity: username, password: "wrong-password")
            Issue.record("wrong password accepted")
        } catch let e as APIError {
            #expect(e.status == 401)
        }

        let again = try await api.login(identity: username, password: password)
        #expect(try await api.authorized(again.token).me().username == username)
    }
}
