import IvynoteKit
import SwiftUI

/// The libraries on this device, as on the desktop client: open one, create
/// a local one, or connect a server as a synced one.
struct LibrariesView: View {
    @Environment(LibraryCatalog.self) private var catalog
    @State private var path: [Route] = []
    @State private var creatingLocal = false
    @State private var renaming: LibraryRef?
    @State private var removing: LibraryRef?
    @State private var nameDraft = ""

    enum Route: Hashable { case connect }

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
                        Text(catalog.libraries.isEmpty ? "本地优先的 Markdown 笔记。先创建或接入一个笔记库。" : "选择要打开的笔记库")
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
                        }
                    }
                }

                Section {
                    Button {
                        nameDraft = catalog.libraries.isEmpty ? "我的笔记" : ""
                        creatingLocal = true
                    } label: {
                        ActionRow(icon: "plus", tint: .secondary, title: "新建本地笔记库", detail: "只保存在这台设备，无需账户，立即可用")
                    }
                    NavigationLink(value: Route.connect) {
                        ActionRow(icon: "icloud", tint: .accentColor, title: "接入服务器", detail: "连接常青笔记服务器，在多台设备间同步")
                    }
                } footer: {
                    Text("本地笔记库不能转换为同步笔记库。要同步本地笔记，请新建一个同步笔记库，再导入从本地笔记库导出的内容。")
                }
                .buttonStyle(.plain)
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: Route.self) { _ in
                ConnectView { server, info, name in
                    let site = info.siteName.trimmingCharacters(in: .whitespaces)
                    catalog.createServer(server, name: name.isEmpty ? (site.isEmpty ? server.host : site) : name)
                }
            }
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

    @ViewBuilder private func actions(_ ref: LibraryRef) -> some View {
        Button("打开", systemImage: "folder") { catalog.open(ref.id) }
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
        if ref.isLocal { return "仅保存在本机" }
        let host = ref.server?.host ?? ""
        return ref.account.map { "\(host) · @\($0)" } ?? host
    }
}

struct LibraryIcon: View {
    let ref: LibraryRef
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: ref.isLocal ? "internaldrive" : "icloud")
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
