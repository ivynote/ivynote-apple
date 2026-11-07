import Foundation

/// `GET /info`: what the server allows before anyone signs in.
public struct ServerInfo: Codable, Equatable, Sendable {
    public var siteName: String
    public var allowRegistration: Bool
    public var hasUsers: Bool
    public var version: String
    public var maxUploadMB: Int

    public init(siteName: String = "", allowRegistration: Bool = false, hasUsers: Bool = true, version: String = "", maxUploadMB: Int = 200) {
        self.siteName = siteName
        self.allowRegistration = allowRegistration
        self.hasUsers = hasUsers
        self.version = version
        self.maxUploadMB = maxUploadMB
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        siteName = try c.decodeIfPresent(String.self, forKey: .siteName) ?? ""
        allowRegistration = try c.decodeIfPresent(Bool.self, forKey: .allowRegistration) ?? false
        hasUsers = try c.decodeIfPresent(Bool.self, forKey: .hasUsers) ?? true
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        maxUploadMB = try c.decodeIfPresent(Int.self, forKey: .maxUploadMB) ?? 200
    }

    /// The first account on an empty server becomes its admin, so sign-up is
    /// always open until then.
    public var canRegister: Bool { allowRegistration || !hasUsers }
}

/// The signed-in user, as `GET /me` and the auth endpoints return it.
public struct User: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var username: String
    public var email: String
    public var displayName: String
    public var role: String
    public var status: String
    public var aiAvailable: Bool
    /// The interface language the user chose (`zh`, `en`…); "" follows the device.
    public var language: String

    public init(id: String, username: String, email: String = "", displayName: String = "", role: String = "user", status: String = "active", aiAvailable: Bool = false, language: String = "") {
        self.id = id
        self.username = username
        self.email = email
        self.displayName = displayName
        self.role = role
        self.status = status
        self.aiAvailable = aiAvailable
        self.language = language
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        username = try c.decode(String.self, forKey: .username)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "user"
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "active"
        aiAvailable = try c.decodeIfPresent(Bool.self, forKey: .aiAvailable) ?? false
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
    }

    public var name: String { displayName.isEmpty ? username : displayName }
    public var isAdmin: Bool { role == "admin" }
}

public struct Health: Codable, Equatable, Sendable {
    public var ok: Bool
    public var version: String?
}

struct AuthResponse: Decodable, Sendable {
    var token: String
    var user: User
}

/// Client-side checks matching the server's field limits, so the user sees
/// the problem before a round trip.
public enum Validation {
    public static func username(_ s: String) -> String? {
        s.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.\-]{1,31}/) == nil
            ? L10n.s.usernameRule : nil
    }

    public static func password(_ s: String) -> String? {
        if s.count < 8 { return L10n.s.passwordTooShort }
        if s.utf8.count > 72 { return L10n.s.passwordTooLong }
        return nil
    }
}
