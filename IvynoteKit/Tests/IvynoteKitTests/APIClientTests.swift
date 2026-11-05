import Foundation
import Testing
@testable import IvynoteKit

@Suite struct APIClientTests {
    let server = try! ServerAddress(parsing: "https://notes.example.com")

    @Test func probeReadsInfo() async throws {
        let t = StubTransport([
            "GET /api/v1/health": .json(200, #"{"ok":true,"version":"1.2.0"}"#),
            "GET /api/v1/info": .json(200, #"{"siteName":"Ivy","allowRegistration":false,"hasUsers":false,"version":"1.2.0","maxUploadMB":50,"storageMode":"disk","cdn":false}"#),
        ])
        let info = try await APIClient(server: server, transport: t).probe()
        #expect(info.siteName == "Ivy")
        #expect(info.maxUploadMB == 50)
        #expect(info.canRegister) // empty server: first account becomes admin
    }

    @Test func probeRejectsOtherServers() async {
        let t = StubTransport(["GET /api/v1/health": .json(200, "<html></html>")])
        await #expect(throws: APIError.invalidResponse) {
            try await APIClient(server: server, transport: t).probe()
        }
    }

    @Test func loginSendsCredentialsWithoutToken() async throws {
        let t = StubTransport(["POST /api/v1/auth/login": .json(200, #"{"token":"tok","user":\#(userJSON)}"#)])
        let (token, user) = try await APIClient(server: server, transport: t).login(identity: "ivy", password: "secret-pw")
        #expect(token == "tok")
        #expect(user.name == "Ivy")
        #expect(user.isAdmin)
        let req = try #require(t.sent.first)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: String]
        #expect(body == ["identity": "ivy", "password": "secret-pw"])
    }

    @Test func registerOmitsEmptyOptionalFields() async throws {
        let t = StubTransport(["POST /api/v1/auth/register": .json(200, #"{"token":"tok","user":\#(userJSON)}"#)])
        _ = try await APIClient(server: server, transport: t).register(username: "ivy", password: "secret-pw", email: "", displayName: "")
        let body = try JSONSerialization.jsonObject(with: t.sent[0].httpBody!) as! [String: String]
        #expect(body == ["username": "ivy", "password": "secret-pw"])
    }

    @Test func meSendsBearer() async throws {
        let t = StubTransport(["GET /api/v1/me": .json(200, userJSON)])
        _ = try await APIClient(server: server, token: "tok", transport: t).me()
        #expect(t.sent[0].value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test func mapsErrors() async {
        let t = StubTransport([
            "POST /api/v1/auth/login": .json(401, #"{"error":"invalid credentials","status":401}"#),
            "GET /api/v1/me": .fail(.notConnectedToInternet),
            "GET /api/v1/info": .json(502, "bad gateway"),
        ])
        let api = APIClient(server: server, transport: t)
        do {
            _ = try await api.login(identity: "x", password: "y")
            Issue.record("expected an error")
        } catch let e as APIError {
            #expect(e == .server(status: 401, message: "invalid credentials"))
            #expect(e.endsSession)
            #expect(e.errorDescription == "invalid credentials")
        } catch { Issue.record("unexpected \(error)") }

        do { _ = try await api.me(); Issue.record("expected an error") }
        catch let e as APIError { #expect(e.isTransient); #expect(!e.endsSession) }
        catch { Issue.record("unexpected \(error)") }

        do { _ = try await api.info(); Issue.record("expected an error") }
        catch let e as APIError { #expect(e.isTransient); #expect(e.status == 502) }
        catch { Issue.record("unexpected \(error)") }
    }
}
