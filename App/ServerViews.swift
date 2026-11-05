import IvynoteKit
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

/// Connects a server as a new library: checks it, then names the library.
struct ConnectView: View {
    var onConnected: (_ server: ServerAddress, _ info: ServerInfo, _ name: String) -> Void

    @State private var address = ""
    @State private var name = ""
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
                TextField("名称（可选）", text: $name, prompt: Text("名称 · 默认使用服务器名称"))
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else if let parsed, parsed.isInsecure {
                    Label("使用 http 连接时，密码和笔记以明文传输，请只在可信的局域网内使用。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Text("常青笔记是自托管的，请填写你或管理员部署的服务器地址。接入后用该服务器的账户登录；笔记先保存在本机，联网时自动同步。")
                }
            }

            Section {
                Button(action: connect) {
                    HStack {
                        Spacer()
                        if checking { ProgressView().controlSize(.small) } else { Text("连接") }
                        Spacer()
                    }
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || checking)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("接入服务器")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            if address.isEmpty, let last = UserDefaults.standard.string(forKey: "ivy.lastServer") { address = last }
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
                UserDefaults.standard.set(server.description, forKey: "ivy.lastServer")
                onConnected(server, info, name)
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
