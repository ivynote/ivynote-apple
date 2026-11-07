import IvynoteKit
import StoreKit
import SwiftUI

/// Signs in to a server library: checks the server, then the sign-in form.
struct SignInView: View {
    @Environment(LibraryCatalog.self) private var catalog
    let ref: LibraryRef

    @State private var info: ServerInfo?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let server = ref.server, let info {
                    AuthView(server: server, info: info)
                } else if let error {
                    ContentUnavailableView {
                        Label(L.cannotConnect, systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button(L.retry) { Task { await probe() } }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(ref.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.libraries, systemImage: "books.vertical") { catalog.open(nil) }
                }
            }
        }
        .task { await probe() }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    private func probe() async {
        guard let server = ref.server else { return }
        error = nil
        do { info = try await APIClient(server: server).probe() } catch { self.error = error.localizedDescription }
    }
}

/// Signs in to the sync service and creates the synced library once an
/// account is behind it (guide 6.11).
///
/// The service is chosen here, at the top of the form: the official node
/// that fits the device is preselected, the other one is a tap away, and a
/// self-hosted server sits behind "自定义服务器…".
///
/// With `promoting`, a local library moves to the cloud: only a newly
/// registered account can take it (`LibraryMigrator`), so this offers sign-up only.
struct CloudSignInView: View {
    @Environment(LibraryCatalog.self) private var catalog
    var promoting: LibraryRef?

    enum Mode: Hashable { case register, login }

    @State private var server = SyncRegion.preferred(storefront: nil, region: Locale.current.region?.identifier).server
    @State private var chosen = false
    @State private var info: ServerInfo?
    @State private var probing = false
    @State private var probeError: String?
    @State private var showCustom = false

    @State private var mode: Mode = .register
    @State private var identity = ""
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    @State private var migration = MigrationState()

    private var region: SyncRegion? { SyncRegion.of(server) }
    private var serverTitle: String { region.map { L.officialRegion($0.title) } ?? server.host }
    private var canRegister: Bool { info?.canRegister ?? true }

    var body: some View {
        Form {
            if migration.running || migration.error != nil {
                migrationSection
            } else {
                serverSection
                if promoting == nil && canRegister {
                    Picker("", selection: $mode) {
                        Text(L.register).tag(Mode.register)
                        Text(L.login).tag(Mode.login)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .listRowBackground(Color.clear)
                }
                accountSection
                Section {
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            if busy { ProgressView().controlSize(.small) } else { Text(submitTitle) }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit || busy || probing || info == nil)
                } footer: {
                    if promoting != nil {
                        Text(L.promoteNote)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(promoting == nil ? L.signInTitle : L.turnOnSyncTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showCustom) {
            NavigationStack {
                CustomServerView { address, serverInfo in
                    chosen = true
                    server = address
                    info = serverInfo
                    probeError = nil
                    showCustom = false
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L.cancel) { showCustom = false } }
                }
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 320)
            #endif
        }
        .task {
            // The website may have moved an official node (e.g. a temporary domain):
            // give it a moment to answer, else go on with the last known address.
            let refresh = Task { await RegionDirectory.shared.refresh() }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await refresh.value }
                group.addTask { try? await Task.sleep(for: .milliseconds(1500)) }
                await group.next()
                group.cancelAll()
            }
            if !chosen, let r = region, r.server != server { server = r.server }
            // The App Store country decides which payments work, so it picks the node when known.
            if !chosen, let storefront = await Storefront.current?.countryCode {
                let preferred = SyncRegion.preferred(storefront: storefront, region: nil).server
                if !chosen && preferred != server { server = preferred }
            }
            await probe()
        }
        .onChange(of: server) { Task { await probe() } }
        .onChange(of: mode) { error = nil }
        .onChange(of: info) { if let info, !info.canRegister, promoting == nil { mode = .login } }
    }

    // MARK: Sections

    private var serverSection: some View {
        Section {
            Menu {
                ForEach(SyncRegion.allCases) { r in
                    Button {
                        chosen = true
                        server = r.server
                    } label: {
                        if region == r { Label(L.officialRegion(r.title), systemImage: "checkmark") } else { Text(L.officialRegion(r.title)) }
                    }
                }
                Divider()
                Button(L.customServerEllipsis, systemImage: "server.rack") { showCustom = true }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: region == nil ? "server.rack" : "globe")
                        .foregroundStyle(Color.accentColor)
                    Text(serverTitle).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 4)
                    if probing {
                        ProgressView().controlSize(.small)
                    } else if info != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if probeError != nil {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text(L.syncNode)
        } footer: {
            if let probeError {
                VStack(alignment: .leading, spacing: 4) {
                    Text(region != nil ? L.nodeUnreachable : probeError).foregroundStyle(.red)
                    Button(L.retry) { Task { await probe() } }.font(.footnote)
                }
            } else if promoting == nil {
                Text(L.signInHint)
            } else if let promoting {
                Text(L.promoteHint(promoting.name))
            }
        }
    }

    @ViewBuilder private var accountSection: some View {
        Section {
            if mode == .login && promoting == nil {
                TextField(L.usernameOrEmail, text: $identity)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            } else {
                TextField(L.username, text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField(L.emailOptional, text: $email)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
            }
            SecureField(isRegistering ? L.passwordMin8 : L.password, text: $password)
                .textContentType(isRegistering ? .newPassword : .password)
                .onSubmit(submit)
        } footer: {
            if let error {
                Text(error).foregroundStyle(.red)
            } else if let info, !info.hasUsers, region == nil {
                Text(L.firstAdmin)
            } else if promoting != nil, let info, !info.canRegister {
                Text(L.registrationClosed).foregroundStyle(.red)
            }
        }
    }

    private var migrationSection: some View {
        Section {
            if migration.running {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(migration.text)
                    }
                    ProgressView(value: migration.share)
                }
                .padding(.vertical, 4)
            } else if let message = migration.error {
                Text(message).foregroundStyle(.red)
                Button(L.continueMigration) { Task { await resume() } }
            }
        } header: {
            Text(L.turnOnSyncTitle)
        }
    }

    // MARK: Actions

    private var isRegistering: Bool { promoting != nil || mode == .register }
    private var submitTitle: String { promoting != nil ? L.registerAndSync : (mode == .login ? L.login : L.register) }

    private var canSubmit: Bool {
        if isRegistering { return canRegister && !username.isEmpty && !password.isEmpty }
        return !identity.isEmpty && !password.isEmpty
    }

    private var libraryName: String {
        if let promoting { return promoting.name }
        if region != nil { return L.defaultLibraryName }
        let site = (info?.siteName ?? "").trimmingCharacters(in: .whitespaces)
        return site.isEmpty || site.lowercased() == "ivynote" ? server.host : site
    }

    private func probe() async {
        let target = server
        probing = true
        probeError = nil
        info = nil
        defer { if target == server { probing = false } }
        do {
            let result = try await APIClient(server: target).probe()
            if target == server { info = result }
        } catch {
            if target == server { probeError = error.localizedDescription }
        }
    }

    private func submit() {
        guard canSubmit, !busy, info != nil else { return }
        if isRegistering, let problem = Validation.username(username) ?? Validation.password(password) {
            error = problem
            return
        }
        error = nil
        busy = true
        let api = APIClient(server: server)
        let target = server
        Task {
            defer { busy = false }
            do {
                let result = isRegistering
                    ? try await api.register(username: username, password: password,
                                             email: email.trimmingCharacters(in: .whitespaces), displayName: "")
                    : try await api.login(identity: identity.trimmingCharacters(in: .whitespaces), password: password)
                password = ""
                if let local = promoting {
                    migration.account = (target, result.token, result.user)
                    await migrate(local)
                } else {
                    try catalog.createSignedIn(target, name: libraryName, token: result.token, user: result.user)
                }
            } catch let e as APIError where e.status == 401 && !isRegistering {
                error = L.wrongCredentials
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func resume() async {
        guard let local = promoting else { return }
        await migrate(local)
    }

    /// Copies the local library into the new account, then opens it as a synced library.
    private func migrate(_ local: LibraryRef) async {
        guard let account = migration.account else { return }
        let state = migration
        state.error = nil
        state.running = true
        state.progress = nil
        defer { state.running = false }
        do {
            let content = try LibraryMigrator.Content.read(from: catalog.storeURL(for: local.id))
            let migrator = LibraryMigrator(api: APIClient(server: account.server, token: account.token), device: Library.deviceID())
            let result = try await migrator.run(content) { p in await state.update(p) }
            let missed = result.rejected.count + result.skippedFiles.count
            if missed > 0 {
                state.error = L10n.s.migrationRejected(missed)
            }
            let ref = try catalog.createSignedIn(account.server, name: libraryName, token: account.token, user: account.user)
            catalog.markMigrated(local.id, to: ref.id)
        } catch let e as LibraryMigrator.Failure {
            state.error = e.localizedDescription
        } catch {
            state.error = L10n.s.migrationInterrupted(error.localizedDescription)
        }
    }
}

/// Progress of moving a local library, updated from the migrator.
@MainActor
@Observable
final class MigrationState {
    var running = false
    var progress: LibraryMigrator.Progress?
    var error: String?
    /// The new account, kept to retry without signing up again.
    var account: (server: ServerAddress, token: String, user: User)?

    func update(_ p: LibraryMigrator.Progress) { progress = p }

    var text: String {
        guard let p = progress else { return L10n.s.preparing }
        switch p.phase {
        case .check: return L10n.s.preparing
        case .files: return L10n.s.uploadingFiles(p.done, p.total)
        case .notes: return L10n.s.uploadingNotes(p.done, p.total)
        case .done: return L10n.s.migrationDone
        }
    }

    var share: Double {
        guard let p = progress else { return 0 }
        switch p.phase {
        case .check: return 0.02
        // Files first, then notes: each takes about half the bar.
        case .files: return 0.02 + 0.48 * (p.total > 0 ? Double(p.done) / Double(p.total) : 1)
        case .notes: return 0.5 + 0.5 * (p.total > 0 ? Double(p.done) / Double(p.total) : 1)
        case .done: return 1
        }
    }
}

/// A self-hosted server: checks the address, then hands it back.
struct CustomServerView: View {
    var onPick: (_ server: ServerAddress, _ info: ServerInfo) -> Void

    @State private var address = ""
    @State private var checking = false
    @State private var error: String?

    private var parsed: ServerAddress? { try? ServerAddress(parsing: address) }

    var body: some View {
        Form {
            Section {
                TextField(L.serverAddress, text: $address, prompt: Text("https://notes.example.com"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit(connect)
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else if let parsed, parsed.isInsecure {
                    Label(L.insecureWarning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Text(L.customServerHint)
                }
            }

            Section {
                Button(action: connect) {
                    HStack {
                        Spacer()
                        if checking { ProgressView().controlSize(.small) } else { Text(L.useServer) }
                        Spacer()
                    }
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || checking)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L.customServer)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            if address.isEmpty, let last = UserDefaults.standard.string(forKey: "ivy.lastServer"),
               let s = try? ServerAddress(parsing: last), SyncRegion.of(s) == nil {
                address = last
            }
        }
    }

    private func connect() {
        guard !checking else { return }
        error = nil
        let server: ServerAddress
        do { server = try ServerAddress(parsing: address) } catch {
            self.error = error.localizedDescription
            return
        }
        checking = true
        Task {
            defer { checking = false }
            do {
                let info = try await APIClient(server: server).probe()
                onPick(server, info)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct AuthView: View {
    @Environment(SessionStore.self) private var session
    let server: ServerAddress
    let info: ServerInfo

    enum Mode: Hashable { case login, register }

    @State private var mode: Mode = .login
    @State private var identity = ""
    @State private var username = ""
    @State private var email = ""
    @State private var displayName = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    private var firstAccount: Bool { !info.hasUsers }

    var body: some View {
        Form {
            if let notice = session.notice, mode == .login {
                Section { Label(notice, systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange) }
            }

            if info.canRegister && !firstAccount {
                Picker("", selection: $mode) {
                    Text(L.login).tag(Mode.login)
                    Text(L.register).tag(Mode.register)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowBackground(Color.clear)
            }

            Section {
                if mode == .login {
                    TextField(L.usernameOrEmail, text: $identity)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } else {
                    TextField(L.username, text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField(L.emailOptional, text: $email)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField(L.displayNameOptional, text: $displayName)
                        .textContentType(.name)
                }
                SecureField(L.password, text: $password)
                    .textContentType(mode == .login ? .password : .newPassword)
                    .onSubmit(submit)
            } header: {
                Text(info.siteName.isEmpty ? server.host : info.siteName)
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else if firstAccount {
                    Text(L.firstAdmin)
                }
            }

            Section {
                Button(action: submit) {
                    HStack {
                        Spacer()
                        if busy { ProgressView().controlSize(.small) } else { Text(mode == .login ? L.login : L.createAccount) }
                        Spacer()
                    }
                }
                .disabled(!canSubmit || busy)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(mode == .login ? L.login : L.register)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { if firstAccount { mode = .register } }
        .onChange(of: mode) { error = nil }
    }

    private var canSubmit: Bool {
        mode == .login ? !identity.isEmpty && !password.isEmpty : !username.isEmpty && !password.isEmpty
    }

    private func submit() {
        guard canSubmit, !busy else { return }
        if mode == .register {
            if let problem = Validation.username(username) ?? Validation.password(password) {
                error = problem
                return
            }
        }
        error = nil
        busy = true
        let api = session.client(for: server)
        Task {
            defer { busy = false }
            do {
                let result = mode == .login
                    ? try await api.login(identity: identity.trimmingCharacters(in: .whitespaces), password: password)
                    : try await api.register(username: username, password: password,
                                             email: email.trimmingCharacters(in: .whitespaces),
                                             displayName: displayName.trimmingCharacters(in: .whitespaces))
                try session.signIn(server: server, token: result.token, user: result.user)
                password = ""
            } catch let e as APIError where e.status == 401 && mode == .login {
                error = L.wrongCredentials
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
