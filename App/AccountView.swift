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
                Section("用户") {
                    LabeledContent("名称", value: account.user.name)
                    LabeledContent("用户名", value: account.user.username)
                    if !account.user.email.isEmpty { LabeledContent("邮箱", value: account.user.email) }
                    LabeledContent("角色", value: account.user.isAdmin ? "管理员" : "用户")
                }
                Section("同步 · \(library.ref.name)") {
                    LabeledContent("服务器", value: account.server.description)
                    LabeledContent("状态") { SyncStatusView() }
                    LabeledContent("笔记", value: "\(engine.liveNotes.count)")
                    LabeledContent("本设备", value: engine.device)
                    Button("立即同步") { Task { await engine.sync() } }
                        .disabled(engine.state.status == .syncing)
                    if account.user.isAdmin {
                        Button("打开管理后台") { openURL(account.server.base.appending(path: "admin")) }
                    }
                }
                Section {
                    Button(role: .destructive) { confirmSignOut = true } label: {
                        if signingOut { ProgressView() } else { Text("退出登录") }
                    }
                    .disabled(signingOut)
                    .confirmationDialog("退出登录？", isPresented: $confirmSignOut) {
                        Button("退出登录", role: .destructive) { signOut() }
                    } message: {
                        Text(signOutMessage)
                    }
                } footer: {
                    Text("退出后，本设备上这个笔记库的副本会被删除；服务器上的数据不受影响。重新登录后会再次下载。")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("账户")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
    }

    private var signOutMessage: String {
        let s = engine.state
        let unsynced = s.pending + s.blocked
        return unsynced > 0
            ? "还有 \(unsynced) 条更改没有同步到服务器，退出后会丢失。"
            : "这台设备的登录令牌会被撤销，本地数据会被删除。"
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
