import IvynoteKit
import SwiftUI

/// Placeholder shell for the signed-in app. The library tree and the note
/// list arrive with the local store and the sync engine.
struct HomeView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL
    let account: StoredAccount

    @Environment(\.horizontalSizeClass) private var sizeClass
    // Nothing selected on iPhone, so the app opens on the sidebar instead of
    // pushing straight into a detail page; wide layouts preselect "all".
    @State private var selection: String?
    @State private var confirmSignOut = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("笔记") {
                    Label("全部笔记", systemImage: "note.text").tag("all")
                    Label("回收站", systemImage: "trash").tag("trash")
                }
                Section("账户") {
                    Label("账户", systemImage: "person.crop.circle").tag("account")
                }
            }
            .navigationTitle("常青笔记")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            #endif
        } detail: {
            switch selection {
            case "account": accountView
            default:
                ContentUnavailableView("同步引擎开发中", systemImage: "leaf",
                                       description: Text("登录已完成。本地数据库与同步将在下一步实现。"))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if session.isOffline {
                Label("离线：正在使用本地数据", systemImage: "wifi.slash")
                    .font(.footnote)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 8)
            }
        }
        .refreshable { await session.refresh() }
        .onAppear { if selection == nil && sizeClass != .compact { selection = "all" } }
    }

    private var accountView: some View {
        Form {
            Section("用户") {
                LabeledContent("名称", value: account.user.name)
                LabeledContent("用户名", value: account.user.username)
                if !account.user.email.isEmpty { LabeledContent("邮箱", value: account.user.email) }
                LabeledContent("角色", value: account.user.isAdmin ? "管理员" : "用户")
            }
            Section("服务器") {
                LabeledContent("地址", value: account.server.description)
                if account.user.isAdmin {
                    Button("打开管理后台") { openURL(account.server.base.appending(path: "admin")) }
                }
            }
            Section {
                // The dialog hangs off the button so its popover points at it.
                Button("退出登录", role: .destructive) { confirmSignOut = true }
                    .confirmationDialog("退出登录？", isPresented: $confirmSignOut) {
                        Button("退出登录", role: .destructive) { Task { await session.signOut() } }
                    } message: {
                        Text("这台设备的登录令牌会被撤销。")
                    }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("账户")
    }
}
