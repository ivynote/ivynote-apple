import IvynoteKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Opens the signed-in account's library and drives it with the app lifecycle.
struct SignedInView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    let account: StoredAccount

    @State private var library: Library?
    @State private var editor: EditorHost?
    @State private var openError: String?

    var body: some View {
        Group {
            if let library, let editor {
                LibraryView()
                    .environment(library)
                    .environment(library.engine)
                    .environment(editor)
            } else if let openError {
                ContentUnavailableView("无法打开本地数据", systemImage: "exclamationmark.triangle", description: Text(openError))
            } else {
                ProgressView()
            }
        }
        .task { open() }
        .onChange(of: scenePhase) { _, phase in handle(phase) }
    }

    private func open() {
        guard library == nil else { return }
        do {
            let lib = try Library(account: account)
            lib.engine.onUnauthorized = { [weak session] in session?.sessionRejected() }
            library = lib
            editor = EditorHost(account: account, engine: lib.engine)
            if scenePhase == .active { lib.activate() }
        } catch {
            openError = error.localizedDescription
        }
    }

    private func handle(_ phase: ScenePhase) {
        guard let library else { return }
        switch phase {
        case .active:
            library.activate()
            Task { await session.refresh() }
        case .background:
            library.deactivate()
            // Ask for time to push what was just written (guide 6.8).
            #if os(iOS)
            let app = UIApplication.shared
            var id = UIBackgroundTaskIdentifier.invalid
            id = app.beginBackgroundTask(withName: "ivy.sync") { app.endBackgroundTask(id) }
            Task {
                await library.flush()
                app.endBackgroundTask(id)
            }
            #else
            Task { await library.flush() }
            #endif
        default:
            library.engine.persistNow()
        }
    }
}
