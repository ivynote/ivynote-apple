import IvynoteKit
import SwiftUI
import UniformTypeIdentifiers

/// 分享笔记 (guide 11.6, the web's ShareDialog): a public link that always
/// carries a password, its expiry and visits; then copying the note as rich
/// text or Markdown, or exporting it as a `.md` file. The link needs the
/// server; copying and exporting fall back to the local text offline.
struct ShareView: View {
    @Environment(SyncEngine.self) private var engine
    @Environment(Library.self) private var library
    @Environment(EditorHost.self) private var host
    @Environment(\.dismiss) private var dismiss
    let noteID: String

    @State private var share: Share?
    @State private var loading = true
    @State private var saving = false
    /// The link could not be read: offline, or the server is unreachable.
    @State private var offline = false
    @State private var error: String?
    @State private var password = ""
    /// Turning the link on asks for a password first; so does changing it.
    @State private var enabling = false
    @State private var changing = false
    @State private var notice: String?
    @State private var exporting: MarkdownFile?

    var body: some View {
        NavigationStack {
            Form {
                if library.api == nil {
                    Section {
                        Text(L.localNoShare)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else if loading {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }
                } else if offline {
                    Section {
                        Label(L.shareNeedsNetwork, systemImage: "wifi.slash").foregroundStyle(.secondary)
                        Button(L.retry) { Task { await load() } }
                    }
                } else {
                    linkSection
                    if asking { passwordSection }
                    if live, let share { detailsSection(share) }
                }
                exportSection
            }
            .formStyle(.grouped)
            .navigationTitle(L.shareNote)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L.done) { dismiss() } }
            }
            .alert(L.error, isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(L.ok, role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
            .overlay(alignment: .bottom) { NoticeToast(text: $notice) }
            .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                          document: exporting, contentType: .markdownText, defaultFilename: exporting?.name) { result in
                if case .failure(let e) = result { error = e.localizedDescription }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
        .task { await load() }
    }

    private var note: Note? { engine.notes[noteID] }
    private var live: Bool { share?.enabled == true && share?.hasPassword == true }
    private var asking: Bool { enabling || changing || (share?.enabled == true && share?.hasPassword == false) }
    private var link: String { share.flatMap { library.api?.shareURL($0).absoluteString } ?? "" }
    private var title: String { note.map(displayTitle) ?? L.untitled }

    // MARK: Sections

    private var linkSection: some View {
        Section {
            Toggle(isOn: Binding(get: { live || enabling }, set: { toggle($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.publicLink)
                    Text(L.publicLinkHint).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .disabled(saving)
        }
    }

    private var passwordSection: some View {
        Section {
            HStack {
                TextField(L.newPasswordPlaceholder, text: $password)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit(submitPassword)
                Button(L.generate) { password = Share.generatePassword() }
                    .buttonStyle(.borderless)
            }
            if !password.isEmpty && !Share.validPassword(password) {
                Text(L.passwordMin6).font(.footnote).foregroundStyle(.red)
            }
            HStack {
                if changing {
                    Button(L.cancel) { changing = false; password = "" }.buttonStyle(.borderless)
                }
                Spacer()
                Button(action: submitPassword) {
                    if saving { ProgressView().controlSize(.small) } else { Text(changing ? L.save : L.createLink) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!Share.validPassword(password) || saving)
            }
        } footer: {
            Label(share?.enabled == true && share?.hasPassword == false
                  ? L.legacyShare
                  : L.needPassword, systemImage: "lock")
        }
    }

    private func detailsSection(_ share: Share) -> some View {
        Section {
            HStack {
                Text(link)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button(L.copyLink) { copy(link) }.buttonStyle(.borderless)
            }
            if share.expired {
                Text(L.shareExpired).font(.footnote).foregroundStyle(.red)
            }
            LabeledContent(L.accessPassword) {
                HStack(spacing: 12) {
                    if share.password.isEmpty {
                        Text(L.passwordSet).foregroundStyle(.secondary)
                    } else {
                        Text(share.password).font(.system(.body, design: .monospaced).weight(.medium)).textSelection(.enabled)
                        Button { copy(share.password) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L.copyPassword)
                    }
                    if !changing {
                        Button(L.change) {
                            changing = true
                            password = Share.generatePassword()
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            if !share.password.isEmpty {
                Button(L.copyLinkAndPassword, systemImage: "doc.on.doc") { copy(message(share)) }
                ShareLink(item: message(share)) { Label(L.sendViaApp, systemImage: "square.and.arrow.up") }
            }
            Picker(L.expires, selection: Binding(get: { -2 }, set: { days in save(days: days) })) {
                Text(share.expiresAt > 0 ? L.keepCurrent(Date(timeIntervalSince1970: Double(share.expiresAt) / 1000).formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L.locale))) : L.neverExpires).tag(-2)
                Text(L.days(1)).tag(1)
                Text(L.days(7)).tag(7)
                Text(L.days(30)).tag(30)
                if share.expiresAt > 0 { Text(L.neverExpires).tag(0) }
            }
            .disabled(saving)
            LabeledContent(L.views, value: L.timesCount(share.views))
        }
    }

    private var exportSection: some View {
        Section {
            Button(L.copyRich, systemImage: "doc.richtext") { Task { await copyAs(rich: true) } }
            Button(L.copyMarkdown, systemImage: "doc.plaintext") { Task { await copyAs(rich: false) } }
            Button(L.exportMd, systemImage: "square.and.arrow.down") { Task { await export() } }
        } header: {
            Text(L.copyOrExport)
        } footer: {
            Text(offline || library.api == nil
                 ? L.copyAsOffline
                 : L.copyAsHint)
        }
    }

    // MARK: Actions

    private func load() async {
        guard let api = library.api else { loading = false; return }
        loading = true
        enabling = false
        changing = false
        defer { loading = false }
        do {
            share = try await api.share(noteID)
            offline = false
            if share?.enabled == true && share?.hasPassword == false { password = Share.generatePassword() }
        } catch let e as APIError where e.isTransient {
            offline = true
        } catch let e as APIError where e.status == 404 {
            // Not on the server yet: push it, then the link can be made.
            await engine.sync()
            share = try? await api.share(noteID)
            offline = false
        } catch {
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    private func save(enabled: Bool? = nil, password newPassword: String? = nil, days: Int? = nil) -> Task<Void, Never> {
        Task {
            guard let api = library.api else { return }
            saving = true
            defer { saving = false }
            let on = enabled ?? share?.enabled ?? true
            var expiresAt = share?.expiresAt ?? 0
            if let days, days >= 0 {
                expiresAt = days > 0 ? Millis((Date().timeIntervalSince1970 + Double(days) * 86_400) * 1000) : 0
            } else if days != nil {
                return // "keep current"
            }
            do {
                // A note created offline has to reach the server first.
                if note?.seq == 0 { await engine.sync() }
                share = try await api.setShare(noteID, enabled: on, password: newPassword, expiresAt: expiresAt)
                if newPassword != nil {
                    password = ""
                    enabling = false
                    changing = false
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func toggle(_ on: Bool) {
        if !on {
            enabling = false
            if share?.enabled == true { save(enabled: false) }
            return
        }
        // A link that already has a password simply reopens.
        if share?.hasPassword == true {
            save(enabled: true)
        } else {
            password = Share.generatePassword()
            enabling = true
        }
    }

    private func submitPassword() {
        guard Share.validPassword(password) else { return }
        save(enabled: true, password: password)
    }

    private func message(_ share: Share) -> String {
        L.shareMessage(title, link, share.password)
    }

    private func copy(_ text: String) {
        Clipboard.copy(text)
        withAnimation { notice = L.copied }
    }

    /// The note with public attachment links; offline, the local text as is.
    private func publicMarkdown() async throws -> String {
        guard let note else { return "" }
        let local = (note.title.isEmpty ? "" : "# \(note.title)\n\n") + note.body
        guard let api = library.api, !offline else { return local }
        // The server renders the export, so it needs the latest edits first.
        await engine.sync()
        do {
            return try await api.exportNote(noteID, public: true)
        } catch let e as APIError where e.isTransient {
            return local
        }
    }

    private func copyAs(rich: Bool) async {
        do {
            let md = try await publicMarkdown()
            if rich, let html = await host.render(md) {
                Clipboard.copy(md, html: html)
            } else {
                Clipboard.copy(md)
            }
            withAnimation { notice = L.copied }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func export() async {
        do {
            let md = try await publicMarkdown()
            let name = (note?.title.isEmpty == false ? note!.title : "untitled")
                .replacing(/[\\\/:*?"<>|]/, with: "-")
            exporting = MarkdownFile(name: name + ".md", text: md)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension UTType {
    static var markdownText: UTType { UTType("net.daringfireball.markdown") ?? .plainText }
}

/// A note as a `.md` file, for the file exporter.
struct MarkdownFile: FileDocument {
    static var readableContentTypes: [UTType] { [.markdownText, .plainText] }

    var name: String
    var text: String

    init(name: String, text: String) {
        self.name = name
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        name = configuration.file.filename ?? "note.md"
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
