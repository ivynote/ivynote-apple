import IvynoteKit
import SwiftUI

@main
struct IvynoteApp: App {
    @State private var catalog: LibraryCatalog = {
        let c = LibraryCatalog()
        c.migrateLegacy()
        return c
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(catalog)
                .interfaceLanguage()
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
