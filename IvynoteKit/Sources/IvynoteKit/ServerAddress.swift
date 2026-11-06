import Foundation

/// The address of a self-hosted Ivynote server, normalized from what the user typed.
///
/// `base` never ends with a slash and never includes `/api/v1`, so
/// `https://notes.example.com/`, `notes.example.com` and
/// `https://notes.example.com/api/v1` all become `https://notes.example.com`.
public struct ServerAddress: Hashable, Codable, Sendable, CustomStringConvertible {
    public let base: URL

    public enum ParseError: Error, Equatable, LocalizedError {
        case empty
        case invalid
        case unsupportedScheme(String)
        case insecureRemote(String)

        public var errorDescription: String? {
            switch self {
            case .empty: L10n.s.serverEmpty
            case .invalid: L10n.s.serverInvalid
            case .unsupportedScheme(let s): L10n.s.unsupportedScheme(s)
            case .insecureRemote(let host): L10n.s.insecureRemote(host)
            }
        }
    }

    public init(parsing input: String) throws {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.empty }
        if !text.contains("://") {
            // No scheme: local addresses default to http, everything else to https.
            let host = text.split(separator: "/").first.map(String.init) ?? text
            let hostOnly = Self.stripPort(host)
            text = (Self.isLocalNetwork(hostOnly) ? "http://" : "https://") + text
        }
        guard var parts = URLComponents(string: text), let host = parts.host, !host.isEmpty else {
            throw ParseError.invalid
        }
        let scheme = (parts.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else { throw ParseError.unsupportedScheme(scheme) }
        // App Transport Security only lets plain http through on the local network.
        if scheme == "http" && !Self.isLocalNetwork(host) { throw ParseError.insecureRemote(host) }

        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/api/v1") { path.removeLast("/api/v1".count) }
        while path.hasSuffix("/") { path.removeLast() }
        parts.scheme = scheme
        parts.host = host.lowercased()
        parts.path = path
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        guard let url = parts.url else { throw ParseError.invalid }
        base = url
    }

    /// `{server}/api/v1`.
    public var apiBase: URL { base.appending(path: "api/v1") }

    public var host: String { base.host() ?? "" }

    public var description: String { base.absoluteString }

    /// Plain http to anything but this device: the user should be warned that
    /// the password and the notes travel unencrypted.
    public var isInsecure: Bool { base.scheme == "http" && !Self.isLoopback(host) }

    static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h == "localhost" || h.hasSuffix(".localhost") || h == "::1" || h.hasPrefix("127.")
    }

    /// Hosts for which `NSAllowsLocalNetworking` permits plain http:
    /// unqualified names, `.local`, and IP literals.
    static func isLocalNetwork(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if isLoopback(h) || !h.contains(".") || h.hasSuffix(".local") { return true }
        if h.contains(":") { return true } // IPv6 literal
        let octets = h.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { UInt8($0) != nil }
    }

    private static func stripPort(_ host: String) -> String {
        if host.hasPrefix("[") { return host } // IPv6 literal, possibly with port
        return host.split(separator: ":").first.map(String.init) ?? host
    }
}
