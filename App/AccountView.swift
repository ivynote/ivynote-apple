import IvynoteKit
import SwiftUI

struct AccountView: View {
    @Environment(SessionStore.self) private var session
    @Environment(Library.self) private var library
    @Environment(SyncEngine.self) private var engine
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var confirmSignOut = false
    @State private var signingOut = false

    var body: some View {
        NavigationStack {
            if let account = library.account { form(account) }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func form(_ account: StoredAccount) -> some View {
            Form {
                Section(L.user) {
                    LabeledContent(L.name, value: account.user.name)
                    LabeledContent(L.username, value: account.user.username)
                    if !account.user.email.isEmpty { LabeledContent(L.email, value: account.user.email) }
                    LabeledContent(L.role, value: account.user.isAdmin ? L.admin : L.user)
                }
                // The account's language: kept by the server, on all its devices.
                Section {
                    LanguagePicker()
                } footer: {
                    LanguageHint()
                }
                Section(L.syncSection(library.ref.name)) {
                    LabeledContent(L.server, value: account.server.description)
                    LabeledContent(L.status) { SyncStatusView() }
                    LabeledContent(L.notes, value: "\(engine.liveNotes.count)")
                    LabeledContent(L.thisDevice, value: engine.device)
                    Button(L.syncNow) { Task { await engine.sync() } }
                        .disabled(engine.state.status == .syncing)
                    if account.user.isAdmin {
                        Button(L.openAdmin) { openURL(account.server.base.appending(path: "admin")) }
                    }
                }
                Section {
                    Button(role: .destructive) { confirmSignOut = true } label: {
                        if signingOut { ProgressView() } else { Text(L.signOut) }
                    }
                    .disabled(signingOut)
                    .confirmationDialog(L.signOutTitle, isPresented: $confirmSignOut) {
                        Button(L.signOut, role: .destructive) { signOut() }
                    } message: {
                        Text(signOutMessage)
                    }
                } footer: {
                    Text(L.signOutHint)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L.account)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L.done) { dismiss() } }
            }
    }

    private var signOutMessage: String {
        let s = engine.state
        let unsynced = s.pending + s.blocked
        return unsynced > 0
            ? L.signOutUnsynced(unsynced)
            : L.signOutMessage
    }

    /// Sync, revoke the token, then delete the local copy (guide 6.10).
    private func signOut() {
        signingOut = true
        let library = library
        Task {
            await library.flush()
            await session.signOut()
            library.destroy()
        }
    }
}
