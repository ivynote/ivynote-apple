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
                        Label("无法连接服务器", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重试") { Task { await probe() } }
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
                    Button("笔记库", systemImage: "books.vertical") { catalog.open(nil) }
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
    private var serverTitle: String { region.map { "常青笔记 · \($0.title)" } ?? server.host }
    private var canRegister: Bool { info?.canRegister ?? true }

    var body: some View {
        Form {
            if migration.running || migration.error != nil {
                migrationSection
            } else {
                serverSection
                if promoting == nil && canRegister {
                    Picker("", selection: $mode) {
                        Text("注册").tag(Mode.register)
                        Text("登录").tag(Mode.login)
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
                        Text("本地笔记库只能迁移到新注册的账户。已有账户的话，可以先登录，再在网页版或桌面端的「设置 → 导入」中导入本笔记库导出的内容。")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(promoting == nil ? "登录常青笔记" : "开启多端同步")
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
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { showCustom = false } }
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
                        if region == r { Label("常青笔记 · \(r.title)", systemImage: "checkmark") } else { Text("常青笔记 · \(r.title)") }
                    }
                }
                Divider()
                Button("自定义服务器…", systemImage: "server.rack") { showCustom = true }
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
            Text("同步节点")
        } footer: {
            if let probeError {
                VStack(alignment: .leading, spacing: 4) {
                    Text(region != nil ? "暂时无法连接这个节点" : probeError).foregroundStyle(.red)
                    Button("重试") { Task { await probe() } }.font(.footnote)
                }
            } else if promoting == nil {
                Text("笔记先保存在本机，联网时自动同步到你的所有设备。")
            } else if let promoting {
                Text("注册一个新账户，「\(promoting.name)」会上传到云端，之后在所有设备上同步。")
            }
        }
    }

    @ViewBuilder private var accountSection: some View {
        Section {
            if mode == .login && promoting == nil {
                TextField("用户名或邮箱", text: $identity)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            } else {
                TextField("用户名", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField("邮箱（可选）", text: $email)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
            }
            SecureField(isRegistering ? "密码（至少 8 位）" : "密码", text: $password)
                .textContentType(isRegistering ? .newPassword : .password)
                .onSubmit(submit)
        } footer: {
            if let error {
                Text(error).foregroundStyle(.red)
            } else if let info, !info.hasUsers, region == nil {
                Text("这台服务器还没有账户。你创建的第一个账户将成为管理员。")
            } else if promoting != nil, let info, !info.canRegister {
                Text("这台服务器没有开放注册。").foregroundStyle(.red)
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
                Button("继续迁移") { Task { await resume() } }
            }
        } header: {
            Text("开启多端同步")
        }
    }

    // MARK: Actions

    private var isRegistering: Bool { promoting != nil || mode == .register }
    private var submitTitle: String { promoting != nil ? "注册并开启同步" : (mode == .login ? "登录" : "注册") }

    private var canSubmit: Bool {
        if isRegistering { return canRegister && !username.isEmpty && !password.isEmpty }
        return !identity.isEmpty && !password.isEmpty
    }

    private var libraryName: String {
        if let promoting { return promoting.name }
        if region != nil { return "我的笔记" }
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
                error = "用户名或密码错误"
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
                state.error = "\(missed) 项未能迁移，原内容仍保留在本地笔记库中。"
            }
            let ref = try catalog.createSignedIn(account.server, name: libraryName, token: account.token, user: account.user)
            catalog.markMigrated(local.id, to: ref.id)
        } catch let e as LibraryMigrator.Failure {
            state.error = e.localizedDescription
        } catch {
            state.error = "迁移中断：\(error.localizedDescription)。账户已经创建，点「继续迁移」会从中断处继续，已上传的内容不会重复。"
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
        guard let p = progress else { return "正在准备…" }
        switch p.phase {
        case .check: return "正在准备…"
        case .files: return "正在上传附件 \(p.done)/\(p.total)"
        case .notes: return "正在上传笔记 \(p.done)/\(p.total)"
        case .done: return "迁移完成，正在打开…"
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
                TextField("服务器地址", text: $address, prompt: Text("https://notes.example.com"))
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
                    Label("使用 http 连接时，密码和笔记以明文传输，请只在可信的局域网内使用。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Text("连接你自己或团队部署的常青笔记服务器。")
                }
            }

            Section {
                Button(action: connect) {
                    HStack {
                        Spacer()
                        if checking { ProgressView().controlSize(.small) } else { Text("使用这个服务器") }
                        Spacer()
                    }
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || checking)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("自定义服务器")
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
                    Text("登录").tag(Mode.login)
                    Text("注册").tag(Mode.register)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowBackground(Color.clear)
            }

            Section {
                if mode == .login {
                    TextField("用户名或邮箱", text: $identity)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } else {
                    TextField("用户名", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField("邮箱（可选）", text: $email)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField("显示名（可选）", text: $displayName)
                        .textContentType(.name)
                }
                SecureField("密码", text: $password)
                    .textContentType(mode == .login ? .password : .newPassword)
                    .onSubmit(submit)
            } header: {
                Text(info.siteName.isEmpty ? server.host : info.siteName)
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else if firstAccount {
                    Text("这台服务器还没有账户。你创建的第一个账户将成为管理员。")
                }
            }

            Section {
                Button(action: submit) {
                    HStack {
                        Spacer()
                        if busy { ProgressView().controlSize(.small) } else { Text(mode == .login ? "登录" : "创建账户") }
                        Spacer()
                    }
                }
                .disabled(!canSubmit || busy)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(mode == .login ? "登录" : "注册")
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
                error = "用户名或密码错误"
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
