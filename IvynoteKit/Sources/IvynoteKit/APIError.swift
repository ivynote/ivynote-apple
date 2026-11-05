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
            case 429: "尝试次数过多，请 15 分钟后再试"
            case 500...: "服务器暂时不可用（\(status)）"
            default: message.isEmpty ? "请求失败（\(status)）" : message
            }
        case .unreachable(let detail): "无法连接服务器：\(detail)"
        case .invalidResponse: "这个地址不是常青笔记服务器"
        }
    }
}
