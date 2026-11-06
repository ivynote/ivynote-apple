import Foundation

public enum APIError: Error, Equatable, LocalizedError {
    /// The server answered with an error status and `{"error": "..."}`.
    case server(status: Int, message: String)
    /// No answer: offline, DNS, TLS, timeout. Treat as "work offline, retry later".
    case unreachable(String)
    /// The server answered, but not with what an Ivynote server sends.
    case invalidResponse

    public var status: Int? {
        if case .server(let status, _) = self { status } else { nil }
    }

    /// 401/403: the session is over (token expired or revoked, account disabled).
    public var endsSession: Bool { status == 401 || status == 403 }

    /// Network failures and 5xx: keep working with local data and retry.
    public var isTransient: Bool {
        switch self {
        case .unreachable: true
        case .server(let status, _): status >= 500
        case .invalidResponse: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .server(let status, let message):
            switch status {
            case 413: L10n.s.fileTooLarge
            case 429: L10n.s.tooManyAttempts
            case 500...: L10n.s.serverUnavailable(status)
            default: message.isEmpty ? L10n.s.requestFailedStatus(status) : message
            }
        case .unreachable(let detail): L10n.s.unreachable(detail)
        case .invalidResponse: L10n.s.notIvynote
        }
    }
}
