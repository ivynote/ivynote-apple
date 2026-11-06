import IvynoteKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// 媒体库 (guide 3.4, 11.6): every file of the library with filters, a
/// file name search and a grid; a file's details show where it is used and
/// what can be done with it. Offline it falls back to the synced metadata.
struct MediaLibraryView: View {
    @Environment(SyncEngine.self) private var engine
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    /// Opens a note that uses a file; the library closes first.
    let openNote: (String) -> Void

    @State private var loader: MediaLoader?
    @State private var filter: MediaFilter = .all
    @State private var query = ""
    @State private var list: MediaList?
    @State private var loading = false
    @State private var offline = false
    @State private var error: String?
    @State private var notice: String?
    @State private var pickers = AttachmentPickerState()
    @State private var uploading = 0
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let loader {
                    content.environment(loader)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("媒体库")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, prompt: "搜索文件名")
            .toolbar { toolbar }
            .navigationDestination(for: String.self) { id in
                if let loader {
                    AttachmentDetailView(id: id, initial: item(id), policy: list?.policy ?? MediaList.Policy(), onChange: reload) { noteID in
                        dismiss()
                        openNote(noteID)
                    }
                    .environment(loader)
                }
            }
            .modifier(AttachmentPickers(state: $pickers) { files in upload(files) })
            .alert("出错了", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(error ?? "") }
            .overlay(alignment: .bottom) { NoticeToast(text: $notice) }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 560)
        #endif
        .onAppear { if loader == nil { loader = MediaLoader(api: library.api, engine: engine) } }
        .task(id: "\(filter.rawValue)|\(query)") {
            // Typing: wait for a pause before asking the server.
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            await load()
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        let items = shown
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                filterBar
                if offline {
                    Label("离线 · 显示已同步的文件信息", systemImage: "wifi.slash")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let banner = orphanBanner {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(banner).font(.footnote)
                        Spacer()
                        Button("查看并清理") { filter = .orphaned }.font(.footnote)
                    }
                    .padding(12)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if filter == .all && !engine.uploads.isEmpty && query.isEmpty {
                    queued
                }
                if items.isEmpty && !loading {
                    ContentUnavailableView(filter == .trash ? "回收站是空的" : query.isEmpty ? "还没有文件" : "没有匹配的文件",
                                           systemImage: filter == .trash ? "trash" : "photo.on.rectangle",
                                           description: Text(filter == .all && query.isEmpty ? "在笔记中插入图片或文件，就会出现在这里。" : ""))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 180), spacing: 12)], spacing: 16) {
                        ForEach(items) { a in
                            NavigationLink(value: a.id) { MediaTile(attachment: a, policy: list?.policy) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
        }
        .overlay { if loading && list == nil { ProgressView() } }
        .refreshable { await load() }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(MediaFilter.allCases, id: \.self) { f in
                    Button { filter = f } label: {
                        HStack(spacing: 4) {
                            Text(f.label)
                            if let n = count(f) { Text("\(n)").monospacedDigit().foregroundStyle(.secondary) }
                        }
                        .font(.subheadline.weight(filter == f ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(filter == f ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.quaternary.opacity(0.5)), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var queued: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("等待上传 \(engine.uploads.count)").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(engine.uploads.values.sorted { $0.createdAt > $1.createdAt }) { u in
                HStack(spacing: 10) {
                    AttachmentThumbnail(id: u.id, kind: u.kind, hasThumb: false)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading) {
                        Text(u.name).lineLimit(1)
                        Text(u.failed.map { "未能上传：\($0)" } ?? (engine.isLocal ? "保存在本机" : "联网后自动上传"))
                            .font(.caption).foregroundStyle(u.failed == nil ? Color.secondary : Color.red)
                    }
                    Spacer()
                    Text(u.size.byteText).font(.caption).foregroundStyle(.secondary)
                }
            }
            if engine.uploads.values.contains(where: { $0.failed != nil }) {
                Button("重新上传") { engine.retryFailedUploads() }.font(.footnote)
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("照片或视频", systemImage: "photo.on.rectangle") { pickers.photos = true }
                if AttachmentPickerState.cameraAvailable {
                    Button("拍照", systemImage: "camera") { pickers.camera = true }
                }
                Button("文件", systemImage: "doc") { pickers.files = true }
            } label: {
                if uploading > 0 { ProgressView().controlSize(.small) } else { Label("上传", systemImage: "square.and.arrow.up") }
            }
            .disabled(library.api == nil)
            .help("上传文件")
        }
    }

    // MARK: Data

    /// The server's answer, or the synced metadata offline.
    private var shown: [Attachment] {
        if let list, !offline { return list.items }
        let q = query.trimmingCharacters(in: .whitespaces)
        return engine.attachments.values
            .filter { filter.matches($0) && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func item(_ id: String) -> Attachment? {
        list?.items.first { $0.id == id } ?? engine.attachments[id]
    }

    private func count(_ f: MediaFilter) -> Int? {
        guard f != .trash, let list, !offline else { return nil }
        return list.counts[f.rawValue]
    }

    private var orphanBanner: String? {
        guard filter == .all, let list, !offline, let n = list.counts["orphaned"], n > 0 else { return nil }
        return list.policy.orphanDays > 0
            ? "\(n) 个文件没有被任何笔记引用，将在 \(list.policy.orphanDays) 天后自动移入回收站。"
            : "\(n) 个文件没有被任何笔记引用。"
    }

    private func load() async {
        guard let api = library.api else {
            offline = true
            return
        }
        loading = true
        defer { loading = false }
        do {
            list = try await api.media(filter, query: query)
            offline = false
        } catch let e as APIError where e.isTransient {
            offline = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reload() {
        Task { await load() }
    }

    private func upload(_ files: [AttachmentInserter.File]) {
        guard !files.isEmpty else { return }
        uploading += files.count
        Task {
            var dedup = 0
            for f in files {
                defer { uploading -= 1 }
                do {
                    if let api = library.api, !offline {
                        let res = try await api.upload(f.data, name: f.name, mime: f.mime)
                        engine.putAttachment(res.attachment)
                        if res.duplicate { dedup += 1 }
                    } else {
                        _ = try await engine.addFile(f.data, name: f.name, mime: f.mime)
                        notice = "已保存在本机，联网后自动上传"
                    }
                } catch {
                    self.error = "「\(f.name)」上传失败：\(error.localizedDescription)"
                }
            }
            if dedup > 0 { notice = "重复文件已合并" }
            await load()
        }
    }
}

/// One file in the grid: preview, name, size and how it is used.
private struct MediaTile: View {
    let attachment: Attachment
    let policy: MediaList.Policy?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AttachmentThumbnail(id: attachment.id, kind: attachment.kind, hasThumb: attachment.hasThumb)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if attachment.public {
                        Image(systemName: "globe").font(.caption2).padding(5)
                            .background(.ultraThinMaterial, in: Circle()).padding(5)
                    }
                }
            Text(attachment.name).font(.caption.weight(.medium)).lineLimit(1)
            Text(usage).font(.caption2).foregroundStyle(attachment.isOrphan ? Color.orange : Color.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private var usage: String {
        let size = attachment.size.byteText
        if attachment.isTrashed { return size }
        if attachment.refs > 0 { return "\(size) · 被 \(attachment.refs) 篇引用" }
        if let days = AttachmentDetailView.cleanupDays(attachment, policy: policy) { return "未引用 · \(days) 天后清理" }
        return "\(size) · 未引用"
    }
}

/// A file's details and actions.
struct AttachmentDetailView: View {
    @Environment(SyncEngine.self) private var engine
    @Environment(Library.self) private var library
    @Environment(MediaLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    let id: String
    let initial: Attachment?
    let policy: MediaList.Policy
    /// The file changed or left the list; the grid reloads.
    let onChange: () -> Void
    let openNote: (String) -> Void

    @State private var detail: AttachmentDetail?
    @State private var image: PlatformImage?
    @State private var publicURL: String?
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var renaming = false
    @State private var nameDraft = ""
    @State private var confirmPurge = false
    @State private var quickLook: URL?
    @State private var download: BinaryFile?

    private var attachment: Attachment? { detail?.attachment ?? initial ?? engine.attachments[id] }

    var body: some View {
        Group {
            if let a = attachment {
                Form {
                    Section { preview(a) }
                    Section {
                        LabeledContent("名称") {
                            Text(a.name).multilineTextAlignment(.trailing).textSelection(.enabled)
                        }
                        LabeledContent("类型", value: typeText(a))
                        LabeledContent("存储", value: a.storage == "s3" ? (policy.cdn ? "S3 · 已开启 CDN · 已加密" : "S3 · 已加密") : "服务器磁盘 · 已加密")
                        if !a.sha256.isEmpty {
                            LabeledContent("指纹") {
                                Text("\(a.sha256.prefix(12))…\(a.sha256.suffix(4))").font(.system(.footnote, design: .monospaced))
                            }
                        }
                        LabeledContent("本地引用") {
                            Text("ivy://res/\(a.id)").font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        }
                        if a.public {
                            LabeledContent("公网链接") {
                                Text(publicURL ?? (a.publicUrl.isEmpty ? "/r/…" : a.publicUrl))
                                    .font(.system(.footnote, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                            }
                        }
                        LabeledContent("上传于", value: Date(timeIntervalSince1970: Double(a.createdAt) / 1000).formatted(date: .long, time: .shortened))
                        if a.isTrashed {
                            LabeledContent("移入回收站", value: Date(timeIntervalSince1970: Double(a.trashedAt) / 1000).formatted(date: .long, time: .shortened))
                        }
                    }
                    Section(references(a)) {
                        ForEach(detail?.notes ?? []) { n in
                            Button { openNote(n.id) } label: {
                                Label(n.title.isEmpty ? "无标题" : n.title, systemImage: "doc.text")
                            }
                            .disabled(engine.notes[n.id] == nil)
                        }
                    }
                    actions(a)
                }
                .formStyle(.grouped)
                .disabled(busy)
                .navigationTitle(a.name)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    if !a.isTrashed {
                        ToolbarItem(placement: .primaryAction) {
                            Button("重命名", systemImage: "pencil") {
                                nameDraft = a.name
                                renaming = true
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("文件不存在", systemImage: "questionmark.folder")
            }
        }
        .alert("重命名文件", isPresented: $renaming) {
            TextField("文件名", text: $nameDraft)
            Button("取消", role: .cancel) {}
            Button("保存") { rename() }
        }
        .confirmationDialog("永久删除这个文件？", isPresented: $confirmPurge, titleVisibility: .visible) {
            Button("永久删除", role: .destructive) { act(.purge) }
        } message: {
            Text("引用它的笔记将无法显示它。此操作无法撤销。")
        }
        .alert("出错了", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(error ?? "") }
        .overlay(alignment: .bottom) { NoticeToast(text: $notice) }
        .quickLookPreview($quickLook)
        .fileExporter(isPresented: Binding(get: { download != nil }, set: { if !$0 { download = nil } }),
                      document: download, contentType: download?.type ?? .data, defaultFilename: download?.name) { result in
            if case .failure(let e) = result { error = e.localizedDescription }
        }
        .task(id: id) { await load() }
    }

    @ViewBuilder private func preview(_ a: Attachment) -> some View {
        HStack {
            Spacer()
            Group {
                if let image {
                    Image(platformImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: AttachmentThumbnail.icon(a.kind))
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.secondary)
                        .frame(height: 120)
                }
            }
            .frame(maxHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Spacer()
        }
        .padding(.vertical, 6)
        if a.kind != "image" || image != nil {
            Button("预览", systemImage: "eye") { Task { await openPreview(a) } }
        }
    }

    @ViewBuilder private func actions(_ a: Attachment) -> some View {
        if a.isTrashed {
            Section {
                Button("恢复", systemImage: "arrow.uturn.backward") { act(.restore) }
                Button("永久删除", systemImage: "trash.slash", role: .destructive) { confirmPurge = true }
            }
        } else {
            Section {
                Button(a.public ? "复制公网链接" : "生成公网链接", systemImage: "globe") { act(.publish) }
                if a.public {
                    Button("撤销公网链接", systemImage: "xmark.circle") { act(.unpublish) }
                }
            } footer: {
                Text("公网链接不再受登录保护，任何拿到地址的人都能打开这个文件。")
            }
            Section {
                Button("复制引用", systemImage: "doc.on.doc") {
                    Clipboard.copy(a.markdown)
                    notice = "已复制"
                }
                Button("下载原文件", systemImage: "square.and.arrow.down") { Task { await save(a) } }
                Button("移到回收站", systemImage: "trash", role: .destructive) { act(.trash) }
            }
        }
    }

    private func references(_ a: Attachment) -> String {
        let n = detail?.notes.count ?? a.refs
        return n > 0 ? "被 \(n) 篇笔记引用" : "未引用"
    }

    private func typeText(_ a: Attachment) -> String {
        var parts = [a.mime.split(separator: "/").last.map { $0.uppercased() } ?? a.mime]
        if let w = a.width, let h = a.height, w > 0 { parts.append("\(w)×\(h)") }
        parts.append(a.size.byteText)
        return parts.joined(separator: " · ")
    }

    static func cleanupDays(_ a: Attachment, policy: MediaList.Policy?) -> Int? {
        guard a.isOrphan, a.orphanSince > 0, let days = policy?.orphanDays, days > 0 else { return nil }
        let left = Double(a.orphanSince + Millis(days) * 86_400_000) / 1000 - Date().timeIntervalSince1970
        return max(0, Int((left / 86_400).rounded(.up)))
    }

    // MARK: Actions

    private func load() async {
        if attachment?.kind == "image" { image = await loader.image(id, thumb: false) }
        guard let api = library.api else { return }
        do {
            detail = try await api.attachment(id)
            if let a = detail?.attachment { engine.putAttachment(a) }
        } catch let e as APIError where e.isTransient {
            // Offline: the synced metadata is all there is.
        } catch {
            self.error = error.localizedDescription
        }
    }

    private enum Action { case trash, restore, purge, publish, unpublish }

    private func act(_ action: Action) {
        guard let api = library.api else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                switch action {
                case .trash:
                    engine.putAttachment(try await api.trashAttachment(id))
                case .restore:
                    engine.putAttachment(try await api.restoreAttachment(id))
                case .purge:
                    try await api.purgeAttachment(id)
                    engine.removeAttachment(id)
                    onChange()
                    dismiss()
                    return
                case .publish:
                    let url = try await api.publishAttachment(id)
                    publicURL = url
                    Clipboard.copy(url)
                    notice = "公网链接已复制"
                case .unpublish:
                    engine.putAttachment(try await api.unpublishAttachment(id))
                    publicURL = nil
                }
                onChange()
                await load()
                if action == .trash || action == .restore { dismiss() }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func rename() {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api = library.api, !name.isEmpty, name != attachment?.name else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let a = try await api.renameAttachment(id, to: name)
                engine.putAttachment(a)
                detail?.attachment = a
                onChange()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func openPreview(_ a: Attachment) async {
        do {
            quickLook = try await loader.file(a.id, name: a.name)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(_ a: Attachment) async {
        do {
            let data = try await loader.data(a.id)
            download = BinaryFile(name: a.name, type: UTType(mimeType: a.mime) ?? .data, data: data)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A downloaded file, for the file exporter.
struct BinaryFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    var name: String
    var type: UTType
    var data: Data

    init(name: String, type: UTType, data: Data) {
        self.name = name
        self.type = type
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        name = configuration.file.filename ?? "file"
        type = .data
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// A short message at the bottom, gone after a moment (guide 11.4).
struct NoticeToast: View {
    @Binding var text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.background)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.primary, in: Capsule())
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(2.6))
                    withAnimation { self.text = nil }
                }
        }
    }
}
