import IvynoteKit
import SwiftUI

struct AccountView: View {
    @Environment(SessionStore.self) private var session
    @Environment(Library.self) private var library
    @Environment(SyncEngine.self) private var engine
    @Environment(BackgroundUploadManager.self) private var uploads
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var confirmSignOut = false
    @State private var signingOut = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            if let account = library.account {
                form(account)
                    .overlay(alignment: .bottom) { NoticeToast(text: $notice) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 540)
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
                AttachmentCacheSection(notice: $notice)
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
        let uploads = uploads
        let libraryID = library.ref.id
        Task {
            await library.flush()
            await session.signOut()
            uploads.evict(libraryID)
            library.destroy()
        }
    }
}

/// Local attachment cache configuration: local-first toggle, size cap with
/// access-based eviction, current usage and one-tap clear.
struct AttachmentCacheSection: View {
    @Environment(SyncEngine.self) private var engine
    @Binding var notice: String?

    private let settings = AttachmentCacheSettings.shared

    var body: some View {
        let cache = engine.attachmentCache
        let localFirst = Binding(
            get: { settings.localFirst },
            set: { settings.localFirst = $0 }
        )
        let maxBytes = Binding(
            get: { settings.maxBytes },
            set: { settings.maxBytes = $0 }
        )
        Section {
            Toggle(L.localFirstCache, isOn: localFirst)
            if settings.localFirst {
                Picker(L.cacheLimit, selection: maxBytes) {
                    ForEach(AttachmentCacheSettings.presets, id: \.self) { bytes in
                        Text(bytes == 0 ? L.cacheUnlimited : bytes.byteText).tag(bytes)
                    }
                }
            }
            LabeledContent(L.cacheUsage) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(cache.totalBytes.byteText) · \(L.cacheFilesCount(cache.entryCount))")
                        .monospacedDigit()
                    if !engine.uploads.isEmpty {
                        Text(L.cachePendingNote(engine.uploads.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Button(L.clearCache, role: .destructive) {
                cache.clear()
                notice = L.cacheCleared
            }
            .disabled(cache.entryCount == 0 && cache.totalBytes == 0)
        } header: {
            Text(L.attachmentCache)
        } footer: {
            Text(L.localFirstCacheHint)
        }
    }
}

/// Standalone sheet for configuring attachment cache from the Media Library.
struct AttachmentCacheSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            Form {
                AttachmentCacheSection(notice: $notice)
            }
            .formStyle(.grouped)
            .navigationTitle(L.attachmentCache)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L.done) { dismiss() } }
            }
            .overlay(alignment: .bottom) { NoticeToast(text: $notice) }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 340)
        #endif
    }
}
