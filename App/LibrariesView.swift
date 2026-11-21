import IvynoteKit
import SwiftUI

/// The libraries on this device, as on the desktop client. Cloud sync leads:
/// sign in or sign up (the library is created once the account exists);
/// a local library is the quiet alternative and can turn on sync later.
struct LibrariesView: View {
    @Environment(LibraryCatalog.self) private var catalog
    @Environment(BackgroundUploadManager.self) private var uploads
    @State private var path: [Route] = []
    @State private var creatingLocal = false
    @State private var renaming: LibraryRef?
    @State private var removing: LibraryRef?
    @State private var nameDraft = ""

    enum Route: Hashable {
        case cloud
        case turnOnSync(String)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    VStack(spacing: 8) {
                        Image("AppLogo")
                            .resizable()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        Text(catalog.libraries.isEmpty ? L.appName : L.libraries).font(.title2.weight(.semibold))
                        Text(catalog.libraries.isEmpty ? L.welcome : L.pickLibrary)
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                if !catalog.libraries.isEmpty {
                    Section {
                        ForEach(catalog.libraries.sorted { $0.openedAt > $1.openedAt }) { ref in
                            Button { catalog.open(ref.id) } label: { LibraryRow(ref: ref) }
                                .buttonStyle(.plain)
                                .contextMenu { actions(ref) }
                                .swipeActions {
                                    Button(L.remove, systemImage: "trash", role: .destructive) { removing = ref }
                                    Button(L.rename, systemImage: "pencil") { startRename(ref) }
                                }
                                .swipeActions(edge: .leading) {
                                    if ref.canTurnOnSync {
                                        Button(L.turnOnSync, systemImage: "icloud.and.arrow.up") { path.append(.turnOnSync(ref.id)) }
                                            .tint(.accentColor)
                                    }
                                }
                        }
                    }
                }

                if catalog.libraries.isEmpty {
                    // First run: syncing is the way in; local is the quiet alternative.
                    Section {
                        NavigationLink(value: Route.cloud) {
                            HStack(spacing: 12) {
                                Image(systemName: "icloud")
                                    .font(.system(size: 18, weight: .medium))
                                    .frame(width: 40, height: 40)
                                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L.startCloud).font(.body.weight(.semibold))
                                    Text(L.startCloudHint).font(.footnote).opacity(0.85)
                                }
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(.white)
                            .padding(.vertical, 6)
                        }
                        .listRowBackground(Color.accentColor)
                    } footer: {
                        Button(L.localOnly) {
                            nameDraft = L.defaultLibraryName
                            creatingLocal = true
                        }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 14)
                    }
                } else {
                    Section {
                        NavigationLink(value: Route.cloud) {
                            ActionRow(icon: "icloud", tint: .accentColor, title: L.connect, detail: L.connectHint)
                        }
                        Button {
                            nameDraft = ""
                            creatingLocal = true
                        } label: {
                            ActionRow(icon: "plus", tint: .secondary, title: L.newLocal, detail: L.newLocalHint)
                        }
                    } footer: {
                        if catalog.libraries.contains(where: \.canTurnOnSync) {
                            Text(L.canConvert)
                        }
                    }
                    .buttonStyle(.plain)
                }

                // Before signing in: this device's choice.
                Section {
                    LanguagePicker()
                } footer: {
                    LanguageHint()
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .cloud:
                    CloudSignInView()
                case .turnOnSync(let id):
                    if let ref = catalog.library(id), ref.canTurnOnSync {
                        CloudSignInView(promoting: ref)
                    }
                }
            }
            .onAppear(perform: takePendingSync)
            .onChange(of: catalog.pendingSync) { takePendingSync() }
            .alert(L.newLocal, isPresented: $creatingLocal) {
                TextField(L.name, text: $nameDraft)
                Button(L.cancel, role: .cancel) {}
                Button(L.create) { catalog.createLocal(name: nameDraft) }
            } message: {
                Text(L.newLocalMessage)
            }
            .alert(L.renameLibrary, isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField(L.name, text: $nameDraft)
                Button(L.cancel, role: .cancel) {}
                Button(L.save) { if let r = renaming { catalog.rename(r.id, to: nameDraft) } }
            }
            .confirmationDialog(L.removeLibrary, isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { ref in
                Button(L.removeNamed(ref.name), role: .destructive) {
                    uploads.evict(ref.id)
                    catalog.remove(ref.id)
                }
            } message: { ref in
                Text(ref.isLocal
                     ? L.removeLocalMessage(ref.name)
                     : L.removeServerMessage(ref.name))
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    /// "Turn on sync" chosen inside a local library: continue here once it has closed.
    private func takePendingSync() {
        guard let id = catalog.pendingSync else { return }
        catalog.pendingSync = nil
        if catalog.library(id)?.canTurnOnSync == true { path = [.turnOnSync(id)] }
    }

    @ViewBuilder private func actions(_ ref: LibraryRef) -> some View {
        Button(L.open, systemImage: "folder") { catalog.open(ref.id) }
        if ref.canTurnOnSync {
            Button(L.turnOnSync, systemImage: "icloud.and.arrow.up") { path.append(.turnOnSync(ref.id)) }
        }
        Button(L.rename, systemImage: "pencil") { startRename(ref) }
        Divider()
        Button(L.remove, systemImage: "trash", role: .destructive) { removing = ref }
    }

    private func startRename(_ ref: LibraryRef) {
        nameDraft = ref.name
        renaming = ref
    }
}

struct LibraryRow: View {
    @Environment(BackgroundUploadManager.self) private var uploads
    let ref: LibraryRef

    var body: some View {
        HStack(spacing: 12) {
            LibraryIcon(ref: ref)
            VStack(alignment: .leading, spacing: 2) {
                Text(ref.name).font(.body.weight(.medium)).lineLimit(1)
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                if let status = uploads.uploadStatus(for: ref.id) {
                    uploadBadge(status)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.quaternary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func uploadBadge(_ status: UploadStatus) -> some View {
        switch status {
        case .uploading(_, let remaining):
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(L.uploadingFilesBackground(remaining))
            }
            .font(.caption)
            .foregroundStyle(Color.accentColor)
        case .waitingForNetwork(let remaining):
            HStack(spacing: 4) {
                Image(systemName: "wifi.slash")
                Text(L.uploadsWaitingNetwork(remaining))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .failed(let count):
            Text(L.uploadsFailedCount(count))
                .font(.caption)
                .foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }

    private var detail: String {
        if ref.migratedTo != nil { return L.migratedHint }
        if ref.isLocal { return L.localUnsynced }
        let host = ref.server?.host ?? ""
        return ref.account.map { "\(host) · @\($0)" } ?? host
    }
}

struct LibraryIcon: View {
    let ref: LibraryRef
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: ref.migratedTo != nil ? "checkmark.icloud" : ref.isLocal ? "internaldrive" : "icloud")
            .font(.system(size: size * 0.45))
            .foregroundStyle(ref.isLocal ? Color.secondary : Color.accentColor)
            .frame(width: size, height: size)
            .background(ref.isLocal ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

private struct ActionRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
