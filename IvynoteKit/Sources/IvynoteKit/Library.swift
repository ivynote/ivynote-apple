import Foundation
import Network
import Observation

/// One open library: the engine over its database plus, for a server
/// library, what drives sync (start-up, server events, network changes, app
/// lifecycle; guide 6.8). A local library has no account and never syncs.
@MainActor
@Observable
public final class Library {
    public let engine: SyncEngine
    public let ref: LibraryRef
    /// The signed-in account, for a server library.
    public let account: StoredAccount?
    public private(set) var loadError: String?

    /// The REST API with the account's token; nil for a local library.
    @ObservationIgnored public let api: APIClient?
    @ObservationIgnored private let storeURL: URL?
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var online: Bool?
    @ObservationIgnored private var active = false

    public init(ref: LibraryRef, account: StoredAccount?, storeURL: URL?, transport: HTTPTransport = URLSessionTransport()) throws {
        self.ref = ref
        self.account = ref.isLocal ? nil : account
        self.storeURL = storeURL
        api = self.account.map { APIClient(server: $0.server, token: $0.token, transport: transport) }
        engine = SyncEngine(store: try LocalStore(url: storeURL), transport: api, device: Self.deviceID())
        do { try engine.load() } catch { loadError = error.localizedDescription }
    }

    /// The app is (back) in the foreground: sync now and listen for changes.
    public func activate() {
        guard !active else { return }
        active = true
        guard api != nil else { return }
        if engine.hasRetryableUploads {
            engine.resumeUploads()
        }
        Task { await engine.sync() }
        connectEvents()
        startMonitor()
    }

    /// Updates connectivity from the local or app-global path monitor so
    /// background uploads and offline sync recover as soon as a path is up.
    public func setNetworkReachable(_ up: Bool) {
        let wasOffline = (online == false) || (engine.state.status == .offline)
        online = up
        engine.setNetworkReachable(up)
        guard up else { return }
        if active && (wasOffline || engine.state.pending > 0) {
            Task { await engine.sync() }
            connectEvents()
        }
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

    /// Deletes this library's local database.
    public func destroy() {
        close()
        if let storeURL { LocalStore.remove(at: storeURL) }
    }

    // MARK: Server events

    private func connectEvents() {
        events?.cancel()
        guard let api else { return }
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
        setNetworkReachable(up)
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
