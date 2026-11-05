import IvynoteKit
import SwiftUI

@main
struct IvynoteApp: App {
    @State private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .task { await session.restore() }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        #endif
    }
}

struct RootView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        Group {
            switch session.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut:
                OnboardingView()
            case .signedIn(let account):
                SignedInView(account: account)
                    // A different account gets its own library.
                    .id("\(account.server)|\(account.user.id)")
            }
        }
        .animation(.default, value: session.state)
    }
}
