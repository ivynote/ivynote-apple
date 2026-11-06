import IvynoteKit
import SwiftUI

/// The libraries on this device, as on the desktop client. Cloud sync leads:
/// sign in or sign up (the library is created once the account exists);
/// a local library is the quiet alternative and can turn on sync later.
struct LibrariesView: View {
    @Environment(LibraryCatalog.self) private var catalog
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
                        Text(catalog.libraries.isEmpty ? "常青笔记" : "笔记库").font(.title2.weight(.semibold))
                        Text(catalog.libraries.isEmpty ? "本地优先的 Markdown 笔记，在手机、电脑和网页间同步。" : "选择要打开的笔记库")
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
                                    Button("移除", systemImage: "trash", role: .destructive) { removing = ref }
                                    Button("重命名", systemImage: "pencil") { startRename(ref) }
                                }
                                .swipeActions(edge: .leading) {
                                    if ref.canTurnOnSync {
                                        Button("开启同步", systemImage: "icloud.and.arrow.up") { path.append(.turnOnSync(ref.id)) }
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
                                    Text("开始使用 · 多端同步").font(.body.weight(.semibold))
                                    Text("登录或注册，笔记在手机、电脑和网页间自动同步").font(.footnote).opacity(0.85)
                                }
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(.white)
                            .padding(.vertical, 6)
                        }
                        .listRowBackground(Color.accentColor)
                    } footer: {
                        Button("不登录，仅在本机使用") {
                            nameDraft = "我的笔记"
                            creatingLocal = true
                        }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 14)
                    }
                } else {
                    Section {
                        NavigationLink(value: Route.cloud) {
                            ActionRow(icon: "icloud", tint: .accentColor, title: "登录云同步账户", detail: "在多台设备间同步，支持官方节点和自建服务器")
                        }
                        Button {
                            nameDraft = ""
                            creatingLocal = true
                        } label: {
                            ActionRow(icon: "plus", tint: .secondary, title: "新建本地笔记库", detail: "只保存在这台设备，无需账户，立即可用")
                        }
                    } footer: {
                        if catalog.libraries.contains(where: \.canTurnOnSync) {
                            Text("本地笔记库可以随时开启同步：注册新账户后，内容会自动上传。")
                        }
                    }
                    .buttonStyle(.plain)
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
            .alert("新建本地笔记库", isPresented: $creatingLocal) {
                TextField("名称", text: $nameDraft)
                Button("取消", role: .cancel) {}
                Button("创建") { catalog.createLocal(name: nameDraft) }
            } message: {
                Text("笔记只保存在这台设备上，不会同步。")
            }
            .alert("重命名笔记库", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("名称", text: $nameDraft)
                Button("取消", role: .cancel) {}
                Button("保存") { if let r = renaming { catalog.rename(r.id, to: nameDraft) } }
            }
            .confirmationDialog("移除笔记库", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { ref in
                Button("移除「\(ref.name)」", role: .destructive) { catalog.remove(ref.id) }
            } message: { ref in
                Text(ref.isLocal
                     ? "将永久删除「\(ref.name)」里的全部笔记，无法恢复。"
                     : "将从这台设备删除「\(ref.name)」的本地副本和登录状态。服务器上的笔记不受影响，但尚未同步的更改会丢失。")
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
        Button("打开", systemImage: "folder") { catalog.open(ref.id) }
        if ref.canTurnOnSync {
            Button("开启同步", systemImage: "icloud.and.arrow.up") { path.append(.turnOnSync(ref.id)) }
        }
        Button("重命名", systemImage: "pencil") { startRename(ref) }
        Divider()
        Button("移除", systemImage: "trash", role: .destructive) { removing = ref }
    }

    private func startRename(_ ref: LibraryRef) {
        nameDraft = ref.name
        renaming = ref
    }
}

struct LibraryRow: View {
    let ref: LibraryRef

    var body: some View {
        HStack(spacing: 12) {
            LibraryIcon(ref: ref)
            VStack(alignment: .leading, spacing: 2) {
                Text(ref.name).font(.body.weight(.medium)).lineLimit(1)
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.quaternary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var detail: String {
        if ref.migratedTo != nil { return "已迁移到云端，确认无误后可以移除" }
        if ref.isLocal { return "仅保存在本机 · 未同步" }
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
