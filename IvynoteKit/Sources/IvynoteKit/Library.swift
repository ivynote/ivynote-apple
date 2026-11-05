import Foundation
import Network
import Observation

/// One signed-in account's notes on this device: the sync engine plus what
/// drives it (start-up, server events, network changes, app lifecycle; guide 6.8).
@MainActor
@Observable
public final class Library {
    public let engine: SyncEngine
    public let account: StoredAccount
    public private(set) var loadError: String?

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let storeURL: URL?
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var online = true
    @ObservationIgnored private var active = false

    public init(account: StoredAccount, transport: HTTPTransport = URLSessionTransport(), storeURL: URL?? = nil) throws {
        self.account = account
        let url = storeURL ?? LocalStore.url(for: account)
        self.storeURL = url
        api = APIClient(server: account.server, token: account.token, transport: transport)
        engine = SyncEngine(store: try LocalStore(url: url), transport: api, device: Self.deviceID())
        do { try engine.load() } catch { loadError = error.localizedDescription }
    }

    /// The app is (back) in the foreground: sync now and listen for changes.
    public func activate() {
        guard !active else { return }
        active = true
        Task { await engine.sync() }
        connectEvents()
        startMonitor()
    }

    /// The app went to the background: save now, stop listening. The caller
    /// may keep the process alive for `flush()`.
    public func deactivate() {
        active = false
        engine.persistNow()
        events?.cancel()
        events = nil
        monitor?.cancel()
        monitor = nil
    }

    /// One push and pull, e.g. before going to the background or signing out.
    public func flush() async {
        await engine.sync()
        engine.persistNow()
    }

    /// Signs out: sync first, then the caller revokes the token, then
    /// `destroy()` deletes the local copy (guide 6.10).
    public func close() {
        deactivate()
        engine.stop()
    }

    /// Deletes this account's local database.
    public func destroy() {
        close()
        if let storeURL { LocalStore.remove(at: storeURL) }
    }

    // MARK: Server events

    private func connectEvents() {
        events?.cancel()
        let source = SyncEvents(api: api)
        events = Task { [weak self] in
            var delay: Duration = .seconds(3)
            while !Task.isCancelled {
                do {
                    for try await seq in source.stream() {
                        delay = .seconds(3)
                        self?.engine.onServerSeq(seq)
                    }
                } catch let e as APIError where e.endsSession {
                    return // the sync loop reports it
                } catch {}
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(60))
            }
        }
    }

    // MARK: Network

    private func startMonitor() {
        monitor?.cancel()
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(up) }
        }
        m.start(queue: DispatchQueue(label: "app.ivynote.network"))
        monitor = m
    }

    private func networkChanged(_ up: Bool) {
        defer { online = up }
        guard up, !online, active else { return }
        Task { await engine.sync() }
        connectEvents()
    }

    // MARK: Device

    /// This install's HLC node and `device` name, e.g. `ios-a1b2c3d4`.
    public static func deviceID(defaults: UserDefaults = .standard) -> String {
        let key = "ivy.device"
        if let id = defaults.string(forKey: key) { return id }
        #if os(macOS)
        let prefix = "mac"
        #else
        let prefix = "ios"
        #endif
        let id = "\(prefix)-\(newEntityID().prefix(8))"
        defaults.set(id, forKey: key)
        return id
    }
}
