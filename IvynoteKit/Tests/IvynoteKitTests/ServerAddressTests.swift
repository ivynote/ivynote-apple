import Testing
@testable import IvynoteKit

@Suite struct ServerAddressTests {
    @Test(arguments: [
        ("notes.example.com", "https://notes.example.com"),
        ("https://notes.example.com/", "https://notes.example.com"),
        ("  HTTPS://Notes.Example.com/api/v1/ ", "https://notes.example.com"),
        ("https://example.com/ivy/", "https://example.com/ivy"),
        ("https://example.com:8443/ivy/api/v1", "https://example.com:8443/ivy"),
        ("localhost:8080", "http://localhost:8080"),
        ("192.168.1.20:8080", "http://192.168.1.20:8080"),
        ("http://nas.local:8080", "http://nas.local:8080"),
        ("nas:8080", "http://nas:8080"),
        ("https://notes.example.com/?x=1#y", "https://notes.example.com"),
    ])
    func normalizes(input: String, expected: String) throws {
        #expect(try ServerAddress(parsing: input).description == expected)
    }

    @Test func apiBase() throws {
        let s = try ServerAddress(parsing: "https://example.com/ivy")
        #expect(s.apiBase.absoluteString == "https://example.com/ivy/api/v1")
    }

    @Test func rejects() {
        #expect(throws: ServerAddress.ParseError.empty) { try ServerAddress(parsing: "  ") }
        #expect(throws: ServerAddress.ParseError.unsupportedScheme("ftp")) { try ServerAddress(parsing: "ftp://example.com") }
        #expect(throws: ServerAddress.ParseError.insecureRemote("notes.example.com")) { try ServerAddress(parsing: "http://notes.example.com") }
    }

    @Test func insecureWarning() throws {
        #expect(try ServerAddress(parsing: "http://192.168.1.2").isInsecure)
        #expect(try !ServerAddress(parsing: "http://127.0.0.1:8080").isInsecure)
        #expect(try !ServerAddress(parsing: "localhost").isInsecure)
        #expect(try !ServerAddress(parsing: "notes.example.com").isInsecure)
    }
}

@Suite struct ValidationTests {
    @Test func username() {
        #expect(Validation.username("ivy") == nil)
        #expect(Validation.username("a.b-c_d") == nil)
        #expect(Validation.username("a") != nil)
        #expect(Validation.username("_ivy") != nil)
        #expect(Validation.username("有中文") != nil)
    }

    @Test func password() {
        #expect(Validation.password("1234567") != nil)
        #expect(Validation.password("12345678") == nil)
        #expect(Validation.password(String(repeating: "密", count: 25)) != nil) // 75 bytes
    }
}
