import IvynoteKit
import SwiftUI

/// Connect to a server, then sign in or sign up.
struct OnboardingView: View {
    @Environment(SessionStore.self) private var session
    @State private var path: [Connected] = []

    struct Connected: Hashable {
        var server: ServerAddress
        var info: ServerInfo

        static func == (a: Self, b: Self) -> Bool { a.server == b.server }
        func hash(into h: inout Hasher) { h.combine(server) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ConnectView { server, info in path = [Connected(server: server, info: info)] }
                .navigationDestination(for: Connected.self) { c in
                    AuthView(server: c.server, info: c.info)
                }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }
}

struct ConnectView: View {
    @Environment(SessionStore.self) private var session
    var onConnected: (ServerAddress, ServerInfo) -> Void

    @State private var address = ""
    @State private var checking = false
    @State private var error: String?

    private var parsed: ServerAddress? { try? ServerAddress(parsing: address) }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image("AppLogo")
                        .resizable()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text("常青笔记").font(.title2.weight(.semibold))
                    Text("连接到你的常青笔记服务器").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

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
                    Text("常青笔记是自托管的，请填写你或管理员部署的服务器地址。")
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
        .navigationTitle("连接服务器")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            if address.isEmpty, let last = session.lastServer { address = last.description }
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
                let info = try await session.client(for: server).probe()
                onConnected(server, info)
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
