import IvynoteKit
import SwiftUI

@main
struct IvynoteApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var catalog: LibraryCatalog = {
        let c = LibraryCatalog()
        c.migrateLegacy()
        return c
    }()
    @State private var uploads = BackgroundUploadManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(catalog)
                .environment(uploads)
                .interfaceLanguage()
                .task { uploads.scanPendingUploads(catalog: catalog) }
                .onChange(of: scenePhase) { _, phase in
                    uploads.handleScenePhase(phase, catalog: catalog)
                }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        #endif
    }
}

/// The open library, or the list of libraries when none is open.
struct RootView: View {
    @Environment(LibraryCatalog.self) private var catalog

    var body: some View {
        Group {
            if let ref = catalog.active {
                LibraryRoot(ref: ref)
                    // Another library is another world: fresh state for it.
                    .id(ref.id)
            } else {
                LibrariesView()
            }
        }
        .animation(.default, value: catalog.activeID)
    }
}
