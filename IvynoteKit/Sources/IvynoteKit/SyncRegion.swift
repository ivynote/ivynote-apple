import Foundation

/// The official sync service: one node for mainland China, one for
/// everywhere else (guide 6.11). The two are separate services; an account
/// lives on one of them. Any other server is a custom, self-hosted one.
///
/// The addresses are built in and the website can override them
/// (`RegionDirectory`), e.g. a temporary domain while an ICP filing is pending.
public enum SyncRegion: String, CaseIterable, Identifiable, Sendable {
    case cn
    case global

    public var id: String { rawValue }

    /// The address new connections use: the website's, else the built-in one.
    public var server: ServerAddress { RegionDirectory.shared.server(for: self) }

    /// The address built into this version of the app.
    public var builtInServer: ServerAddress {
        switch self {
        case .cn: try! ServerAddress(parsing: "https://web.ivynote.net")
        case .global: try! ServerAddress(parsing: "https://web.ivynote.app")
        }
    }

    public var title: String {
        switch self {
        case .cn: L10n.s.regionCn
        case .global: L10n.s.regionGlobal
        }
    }

    /// The official region of a server, if it is one: its current address, an
    /// alias the website listed, or the built-in address.
    public static func of(_ server: ServerAddress?) -> SyncRegion? {
        RegionDirectory.shared.region(of: server)
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

/// The official region addresses in effect. At start the app asks the website
/// (`GET /api/v1/regions`, ivynote.net then ivynote.app) and keeps the answer
/// for next time; without one it uses the last answer, then the built-in
/// addresses. Only https addresses are taken from the website.
public final class RegionDirectory: @unchecked Sendable {
    public static let shared = RegionDirectory()

    public struct Entry: Equatable, Sendable {
        public var server: ServerAddress
        /// Other addresses of the same service (an earlier or a temporary domain).
        public var aliases: [ServerAddress]
    }

    /// Websites that publish the region addresses, asked in order.
    public static let sites = [URL(string: "https://ivynote.net")!, URL(string: "https://ivynote.app")!]
    static let cacheKey = "ivy.regions"

    private let lock = NSLock()
    private var entries: [SyncRegion: Entry] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.cacheKey), let parsed = Self.parse(data) {
            entries = parsed
        }
    }

    public func entry(for region: SyncRegion) -> Entry {
        lock.withLock { entries[region] } ?? Entry(server: region.builtInServer, aliases: [])
    }

    public func server(for region: SyncRegion) -> ServerAddress { entry(for: region).server }

    public func region(of server: ServerAddress?) -> SyncRegion? {
        guard let server else { return nil }
        for r in SyncRegion.allCases {
            let e = entry(for: r)
            if e.server == server || e.aliases.contains(server) { return r }
        }
        return SyncRegion.allCases.first { $0.builtInServer == server }
    }

    /// Reads the website's answer: `{"regions":[{"id":"cn","url":"https://…","aliases":["https://…"]}]}`.
    /// Regions it leaves out keep the built-in address; unknown ids are ignored.
    /// Nil when nothing in it is usable.
    static func parse(_ data: Data) -> [SyncRegion: Entry]? {
        struct Body: Decodable {
            struct Item: Decodable {
                var id: String
                var url: String
                var aliases: [String]?
            }
            var regions: [Item]
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
        func https(_ s: String) -> ServerAddress? {
            guard s.lowercased().hasPrefix("https://"), let a = try? ServerAddress(parsing: s), a.base.path.isEmpty else { return nil }
            return a
        }
        var out: [SyncRegion: Entry] = [:]
        for item in body.regions {
            guard let region = SyncRegion(rawValue: item.id), out[region] == nil, let server = https(item.url) else { continue }
            var aliases: [ServerAddress] = []
            for a in (item.aliases ?? []).compactMap(https) where a != server && !aliases.contains(a) { aliases.append(a) }
            // The built-in address always stays recognised.
            if region.builtInServer != server && !aliases.contains(region.builtInServer) { aliases.append(region.builtInServer) }
            out[region] = Entry(server: server, aliases: aliases)
        }
        return out.isEmpty ? nil : out
    }

    /// Takes an answer from the website; false when it was not usable.
    @discardableResult
    func apply(_ data: Data) -> Bool {
        guard let parsed = Self.parse(data) else { return false }
        lock.withLock { entries = parsed }
        defaults.set(data, forKey: Self.cacheKey)
        return true
    }

    /// Back to the built-in addresses (tests).
    func reset() {
        lock.withLock { entries = [:] }
        defaults.removeObject(forKey: Self.cacheKey)
    }

    /// Asks the websites in turn; on failure the last known addresses stay. Never throws.
    public func refresh(session: URLSession = .shared) async {
        for site in Self.sites {
            var request = URLRequest(url: site.appending(path: "api/v1/regions"))
            request.timeoutInterval = 6
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            if apply(data) { return }
        }
    }
}
