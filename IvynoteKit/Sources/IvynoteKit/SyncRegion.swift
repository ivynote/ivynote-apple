import Foundation

/// The official sync service: one node for mainland China, one for
/// everywhere else (guide 6.11). The two are separate services; an account
/// lives on one of them. Any other server is a custom, self-hosted one.
public enum SyncRegion: String, CaseIterable, Identifiable, Sendable {
    case cn
    case global

    public var id: String { rawValue }

    public var server: ServerAddress {
        switch self {
        case .cn: try! ServerAddress(parsing: "https://web.ivynote.net")
        case .global: try! ServerAddress(parsing: "https://web.ivynote.app")
        }
    }

    public var title: String {
        switch self {
        case .cn: "中国大陆"
        case .global: "全球"
        }
    }

    /// The official region of a server, if it is one.
    public static func of(_ server: ServerAddress?) -> SyncRegion? {
        guard let server else { return nil }
        return allCases.first { $0.server == server }
    }

    /// The node to preselect, by where the device is, not by its language:
    /// Chinese speakers abroad belong on the global node.
    ///
    /// - Parameters:
    ///   - storefront: the App Store country (`Storefront.countryCode`,
    ///     ISO 3166-1 alpha-3, e.g. `CHN`). It decides which payments work,
    ///     so it wins when known.
    ///   - region: the device region (`Locale.current.region?.identifier`, e.g. `CN`).
    ///   - timeZone: the device time zone identifier.
    public static func preferred(storefront: String?, region: String?, timeZone: String? = TimeZone.current.identifier) -> SyncRegion {
        if let storefront, !storefront.isEmpty { return storefront.uppercased() == "CHN" ? .cn : .global }
        if let region, !region.isEmpty { return region.uppercased() == "CN" ? .cn : .global }
        if let timeZone { return cnTimeZones.contains(timeZone) ? .cn : .global }
        return .global
    }

    // Hong Kong, Macau and Taipei are not here: they are served from the global node.
    static let cnTimeZones: Set<String> = ["Asia/Shanghai", "Asia/Urumqi", "Asia/Chongqing", "Asia/Chungking", "Asia/Harbin", "Asia/Kashgar", "PRC"]
}
