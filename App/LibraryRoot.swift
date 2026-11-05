import IvynoteKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// One library: a local one opens at once; a server one restores its
/// sign-in first and asks for it when there is none.
struct LibraryRoot: View {
    @Environment(LibraryCatalog.self) private var catalog
    let ref: LibraryRef

    @State private var session: SessionStore?

    var body: some View {
        Group {
            if ref.isLocal {
                OpenLibraryView(ref: ref, account: nil)
            } else if let session {
                Group {
                    switch session.state {
                    case .loading:
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .signedOut:
                        SignInView(ref: ref)
                    case .signedIn(let account):
                        OpenLibraryView(ref: ref, account: account)
                            // Another account on the same server: its own engine.
                            .id(account.user.id)
                    }
                }
                .environment(session)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            guard !ref.isLocal, session == nil else { return }
            let s = SessionStore(store: catalog.credentials(for: ref.id))
            session = s
            await s.restore()
        }
    }
}

/// Opens a library's database and drives it with the app lifecycle.
struct OpenLibraryView: View {
    @Environment(LibraryCatalog.self) private var catalog
    @Environment(SessionStore.self) private var session: SessionStore?
    @Environment(\.scenePhase) private var scenePhase
    let ref: LibraryRef
    let account: StoredAccount?

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
                ContentUnavailableView {
                    Label("无法打开本地数据", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(openError)
                } actions: {
                    Button("返回笔记库列表") { catalog.open(nil) }
                }
            } else {
                ProgressView()
            }
        }
        .task { open() }
        .onChange(of: scenePhase) { _, phase in handle(phase) }
        .onDisappear { close() }
    }

    private func open() {
        guard library == nil else { return }
        let url = catalog.storeURL(for: ref.id)
        if let account {
            // Notes of another account on this server must not mix in.
            if let previous = ref.userID, previous != account.user.id { LocalStore.remove(at: url) }
            catalog.signedIn(ref.id, user: account.user)
        }
        do {
            let lib = try Library(ref: ref, account: account, storeURL: url)
            lib.engine.onUnauthorized = { [weak session] in session?.sessionRejected() }
            library = lib
            editor = EditorHost(account: account, engine: lib.engine)
            if scenePhase == .active { lib.activate() }
        } catch {
            openError = error.localizedDescription
        }
    }

    /// Switching libraries: save now, push what is pending, then stop.
    private func close() {
        guard let library else { return }
        library.deactivate()
        Task {
            await library.flush()
            library.close()
        }
    }

    private func handle(_ phase: ScenePhase) {
        guard let library else { return }
        switch phase {
        case .active:
            library.activate()
            if let session { Task { await session.refresh() } }
        case .background:
            library.deactivate()
            guard !ref.isLocal else { return }
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
