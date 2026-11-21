import Foundation
import IvynoteKit
import Network
import Observation
import OSLog
import SwiftUI
#if os(iOS)
import UIKit
#endif

private let uploadLog = Logger(subsystem: "app.ivynote", category: "background-uploads")

/// App-global manager that owns live `Library` instances and keeps attachment
/// uploads (and their normalized note syncs) draining reliably in the
/// background even after the user leaves a note, closes a library back to the
/// library list, or switches to another library.
@MainActor
@Observable
final class BackgroundUploadManager {
    private(set) var libraries: [String: Library] = [:]
    private(set) var isOnline: Bool = true

    @ObservationIgnored private var foregroundID: String?
    @ObservationIgnored private var drainTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private weak var catalogRef: LibraryCatalog?

    init() {
        startMonitor()
    }

    /// Acquires (or reuses) the live `Library` for foreground editing. Reusing
    /// an already-running background uploader guarantees zero SQLite contention
    /// and preserves in-flight upload progress seamlessly.
    func acquire(ref: LibraryRef, account: StoredAccount?, storeURL: URL) throws -> Library {
        drainTasks.removeValue(forKey: ref.id)?.cancel()

        if let existing = libraries[ref.id] {
            let sameAccount = existing.account?.user.id == account?.user.id
                && existing.account?.token == account?.token
                && existing.ref.isLocal == ref.isLocal
            if sameAccount {
                foregroundID = ref.id
                existing.setNetworkReachable(isOnline)
                return existing
            }
            existing.close()
            libraries[ref.id] = nil
        }

        let lib = try Library(ref: ref, account: account, storeURL: storeURL)
        libraries[ref.id] = lib
        foregroundID = ref.id
        lib.setNetworkReachable(isOnline)
        return lib
    }

    /// Called when the user navigates away from an open library (e.g. back to
    /// `LibrariesView` or into another library). Stops live SSE listening to
    /// save battery, but keeps the library alive in the background until all
    /// queued uploads and outbox changes finish draining.
    func releaseFromForeground(_ libraryID: String) {
        if foregroundID == libraryID {
            foregroundID = nil
        }
        guard let lib = libraries[libraryID] else { return }
        lib.deactivate()

        if !lib.ref.isLocal && (lib.engine.hasRetryableUploads || lib.engine.state.pending > 0) {
            uploadLog.info("keeping library \(libraryID, privacy: .public) alive in background (\(lib.engine.uploads.count) uploads, \(lib.engine.state.pending) pending)")
            scheduleBackgroundDrain(for: libraryID)
        } else {
            lib.close()
            libraries[libraryID] = nil
        }
    }

    /// Stops and removes a library immediately (used before signing out or
    /// deleting a library from disk).
    func evict(_ libraryID: String) {
        drainTasks.removeValue(forKey: libraryID)?.cancel()
        if foregroundID == libraryID {
            foregroundID = nil
        }
        if let lib = libraries.removeValue(forKey: libraryID) {
            lib.close()
        }
    }

    /// Scans all synced libraries on disk at launch or foreground return and
    /// spins up headless background uploaders for any library that still has
    /// queued files waiting to reach the server.
    func scanPendingUploads(catalog: LibraryCatalog) {
        catalogRef = catalog
        let fm = FileManager.default
        for ref in catalog.libraries where !ref.isLocal && libraries[ref.id] == nil {
            let storeURL = catalog.storeURL(for: ref.id)
            let uploadsDir = storeURL.deletingLastPathComponent().appending(path: "uploads", directoryHint: .isDirectory)
            guard let items = try? fm.contentsOfDirectory(atPath: uploadsDir.path), !items.isEmpty else {
                continue
            }
            guard let account = try? catalog.credentials(for: ref.id).load() else {
                continue
            }
            do {
                let lib = try Library(ref: ref, account: account, storeURL: storeURL)
                if lib.engine.hasRetryableUploads || lib.engine.state.pending > 0 {
                    libraries[ref.id] = lib
                    lib.setNetworkReachable(isOnline)
                    uploadLog.info("resuming background uploads for library \(ref.id, privacy: .public) (\(lib.engine.uploads.count) queued)")
                    scheduleBackgroundDrain(for: ref.id)
                } else {
                    lib.close()
                }
            } catch {
                uploadLog.error("could not open library \(ref.id, privacy: .public) for background upload: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Handles app-wide scene lifecycle changes so pending uploads across all
    /// libraries get iOS background execution time and resume cleanly on return.
    func handleScenePhase(_ phase: ScenePhase, catalog: LibraryCatalog) {
        catalogRef = catalog
        switch phase {
        case .active:
            scanPendingUploads(catalog: catalog)
            for (id, lib) in libraries where !lib.ref.isLocal {
                lib.setNetworkReachable(isOnline)
                if id != foregroundID && (lib.engine.hasRetryableUploads || lib.engine.state.pending > 0) {
                    scheduleBackgroundDrain(for: id)
                }
            }
        case .background:
            let targets = libraries.values.filter { !$0.ref.isLocal && ($0.engine.hasRetryableUploads || $0.engine.state.pending > 0) }
            guard !targets.isEmpty else { return }
            #if os(iOS)
            let bgTask = GlobalUploadBackgroundTask()
            bgTask.begin()
            Task { [weak self] in
                await self?.flushAll(targets)
                bgTask.end()
            }
            #else
            Task { [weak self] in
                await self?.flushAll(targets)
            }
            #endif
        default:
            for lib in libraries.values {
                lib.engine.persistNow()
            }
        }
    }

    /// Live upload status for a library row on `LibrariesView`.
    func uploadStatus(for libraryID: String) -> UploadStatus? {
        guard let lib = libraries[libraryID], !lib.ref.isLocal else { return nil }
        let status = lib.engine.uploadStatus
        if status != .idle { return status }
        let pending = lib.engine.uploads.values.filter { $0.failed == nil }.count
        if pending > 0 {
            return isOnline ? .uploading(currentID: "", remaining: pending) : .waitingForNetwork(remaining: pending)
        }
        return nil
    }

    func pendingUploadCount(for libraryID: String) -> Int {
        guard let lib = libraries[libraryID], !lib.ref.isLocal else { return 0 }
        return lib.engine.uploads.count
    }

    // MARK: Internals

    private func scheduleBackgroundDrain(for libraryID: String) {
        drainTasks[libraryID]?.cancel()
        drainTasks[libraryID] = Task { [weak self] in
            guard let self, let lib = self.libraries[libraryID] else { return }
            let drained = await lib.engine.drainUploads()
            guard !Task.isCancelled else { return }
            if drained || lib.engine.state.pending > 0 {
                await lib.engine.sync()
                lib.engine.persistNow()
            }
            guard !Task.isCancelled else { return }
            self.drainTasks[libraryID] = nil
            // Release background library once completely drained and not foregrounded.
            if self.foregroundID != libraryID,
               let current = self.libraries[libraryID],
               !current.engine.hasRetryableUploads,
               current.engine.state.pending == 0 {
                uploadLog.info("background uploads finished for library \(libraryID, privacy: .public); closing")
                current.close()
                self.libraries[libraryID] = nil
            }
        }
    }

    private func flushAll(_ targets: [Library]) async {
        for lib in targets {
            _ = await lib.engine.drainUploads()
            await lib.engine.sync()
            lib.engine.persistNow()
        }
        // Clean up any background-only libraries that finished draining.
        for (id, lib) in libraries where id != foregroundID {
            if !lib.engine.hasRetryableUploads && lib.engine.state.pending == 0 {
                drainTasks.removeValue(forKey: id)?.cancel()
                lib.close()
                libraries[id] = nil
            }
        }
    }

    private func startMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.networkChanged(up)
            }
        }
        m.start(queue: DispatchQueue(label: "app.ivynote.global-network"))
        monitor = m
    }

    private func networkChanged(_ up: Bool) {
        isOnline = up
        for (id, lib) in libraries where !lib.ref.isLocal {
            lib.setNetworkReachable(up)
            if up && id != foregroundID && (lib.engine.hasRetryableUploads || lib.engine.state.pending > 0) {
                scheduleBackgroundDrain(for: id)
            }
        }
        if up, let catalog = catalogRef {
            scanPendingUploads(catalog: catalog)
        }
    }
}

#if os(iOS)
@MainActor
private final class GlobalUploadBackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    func begin() {
        id = UIApplication.shared.beginBackgroundTask(withName: "ivy.background.uploads") { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
