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
    @State private var showCacheSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let loader {
                    content.environment(loader)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(L.mediaLibrary)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, prompt: L.searchFiles)
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
            .alert(L.error, isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(L.ok, role: .cancel) {}
            } message: { Text(error ?? "") }
            .overlay(alignment: .bottom) { NoticeToast(text: $notice) }
            .sheet(isPresented: $showCacheSettings) { AttachmentCacheSheet() }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 560)
        #endif
        .onAppear { if loader == nil { loader = MediaLoader(api: library.api, engine: engine) } }
        .onChange(of: engine.uploads.count) { old, new in
            if new < old { reload() }
        }
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
                    Label(L.mediaOffline, systemImage: "wifi.slash")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let banner = orphanBanner {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(banner).font(.footnote)
                        Spacer()
                        Button(L.reviewAndClean) { filter = .orphaned }.font(.footnote)
                    }
                    .padding(12)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if filter == .all && !engine.uploads.isEmpty && query.isEmpty {
                    queued
                }
                if items.isEmpty && !loading {
                    ContentUnavailableView(filter == .trash ? L.mediaTrashEmpty : query.isEmpty ? L.noFiles : L.noMatchingFiles,
                                           systemImage: filter == .trash ? "trash" : "photo.on.rectangle",
                                           description: Text(filter == .all && query.isEmpty ? L.noFilesHint : ""))
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
            Text(L.waitingUploads(engine.uploads.count)).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(engine.uploads.values.sorted { $0.createdAt > $1.createdAt }) { u in
                HStack(spacing: 10) {
                    AttachmentThumbnail(id: u.id, kind: u.kind, hasThumb: false)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading) {
                        Text(u.name).lineLimit(1)
                        Text(u.failed.map { L.notUploaded($0) } ?? (engine.isLocal ? L.savedOnDevice : L.uploadsWhenOnline))
                            .font(.caption).foregroundStyle(u.failed == nil ? Color.secondary : Color.red)
                    }
                    Spacer()
                    Text(u.size.byteText).font(.caption).foregroundStyle(.secondary)
                }
            }
            if engine.uploads.values.contains(where: { $0.failed != nil }) {
                Button(L.retryUpload) { engine.retryFailedUploads() }.font(.footnote)
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button(L.close) { dismiss() } }
        ToolbarItem(placement: .primaryAction) {
            Button(L.cacheSettings, systemImage: "internaldrive") { showCacheSettings = true }
                .help(L.cacheSettings)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button(L.photoOrVideo, systemImage: "photo.on.rectangle") { pickers.photos = true }
                if AttachmentPickerState.cameraAvailable {
                    Button(L.camera, systemImage: "camera") { pickers.camera = true }
                }
                Button(L.file, systemImage: "doc") { pickers.files = true }
            } label: {
                let pending = uploading + (engine.isLocal || engine.state.status == .offline ? 0 : engine.uploads.values.filter { $0.failed == nil }.count)
                if pending > 0 { ProgressView().controlSize(.small) } else { Label(L.upload, systemImage: "square.and.arrow.up") }
            }
            .disabled(library.api == nil)
            .help(L.uploadFiles)
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
            ? L.orphanBanner(n, list.policy.orphanDays)
            : L.orphanBannerNoDays(n)
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
        defer { uploading -= files.count }
        for f in files {
            do {
                _ = try engine.addFileLocal(f.data, name: f.name, mime: f.mime)
            } catch {
                self.error = L.uploadFailed(f.name, error.localizedDescription)
            }
        }
        if offline || engine.state.status == .offline {
            notice = L.savedLocallyUploadLater
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
        if attachment.refs > 0 { return "\(size) · \(L.usedIn(attachment.refs))" }
        if let days = AttachmentDetailView.cleanupDays(attachment, policy: policy) { return L.cleanupIn(days) }
        return "\(size) · \(L.unreferenced)"
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
                        LabeledContent(L.name) {
                            Text(a.name).multilineTextAlignment(.trailing).textSelection(.enabled)
                        }
                        LabeledContent(L.type, value: typeText(a))
                        LabeledContent(L.storage, value: a.storage == "s3" ? (policy.cdn ? L.storageS3CDN : L.storageS3) : L.storageDisk)
                        if !a.sha256.isEmpty {
                            LabeledContent(L.fingerprint) {
                                Text("\(a.sha256.prefix(12))…\(a.sha256.suffix(4))").font(.system(.footnote, design: .monospaced))
                            }
                        }
                        LabeledContent(L.localReference) {
                            Text("ivy://res/\(a.id)").font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        }
                        if a.public {
                            LabeledContent(L.publicUrl) {
                                Text(publicURL ?? (a.publicUrl.isEmpty ? "/r/…" : a.publicUrl))
                                    .font(.system(.footnote, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                            }
                        }
                        LabeledContent(L.uploadedAt, value: Date(timeIntervalSince1970: Double(a.createdAt) / 1000).formatted(Date.FormatStyle(date: .long, time: .shortened).locale(L.locale)))
                        if a.isTrashed {
                            LabeledContent(L.trashedAt, value: Date(timeIntervalSince1970: Double(a.trashedAt) / 1000).formatted(Date.FormatStyle(date: .long, time: .shortened).locale(L.locale)))
                        }
                    }
                    Section(references(a)) {
                        ForEach(detail?.notes ?? []) { n in
                            Button { openNote(n.id) } label: {
                                Label(n.title.isEmpty ? L.untitled : n.title, systemImage: "doc.text")
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
                            Button(L.rename, systemImage: "pencil") {
                                nameDraft = a.name
                                renaming = true
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(L.fileNotFound, systemImage: "questionmark.folder")
            }
        }
        .alert(L.renameFile, isPresented: $renaming) {
            TextField(L.fileName, text: $nameDraft)
            Button(L.cancel, role: .cancel) {}
            Button(L.save) { rename() }
        }
        .confirmationDialog(L.purgeFileTitle, isPresented: $confirmPurge, titleVisibility: .visible) {
            Button(L.deleteForever, role: .destructive) { act(.purge) }
        } message: {
            Text(L.purgeFileMessage)
        }
        .alert(L.error, isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L.ok, role: .cancel) {}
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
            Button(L.preview, systemImage: "eye") { Task { await openPreview(a) } }
        }
    }

    @ViewBuilder private func actions(_ a: Attachment) -> some View {
        if a.isTrashed {
            Section {
                Button(L.restore, systemImage: "arrow.uturn.backward") { act(.restore) }
                Button(L.deleteForever, systemImage: "trash.slash", role: .destructive) { confirmPurge = true }
            }
        } else {
            Section {
                Button(a.public ? L.copyPublicUrl : L.makePublicUrl, systemImage: "globe") { act(.publish) }
                if a.public {
                    Button(L.revokePublicUrl, systemImage: "xmark.circle") { act(.unpublish) }
                }
            } footer: {
                Text(L.publicFilesHint)
            }
            Section {
                Button(L.copyReference, systemImage: "doc.on.doc") {
                    Clipboard.copy(a.markdown)
                    notice = L.copied
                }
                Button(L.downloadOriginal, systemImage: "square.and.arrow.down") { Task { await save(a) } }
                Button(L.moveToTrash, systemImage: "trash", role: .destructive) { act(.trash) }
            }
        }
    }

    private func references(_ a: Attachment) -> String {
        let n = detail?.notes.count ?? a.refs
        return n > 0 ? L.referencedBy(n) : L.unreferenced
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
                    notice = L.publicUrlCopied
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
