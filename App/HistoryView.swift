import IvynoteKit
import SwiftUI

/// A note's saved versions (guide 11.6): the list on one side, the chosen
/// version rendered (or as source) on the other. Restoring goes through the
/// outbox like any edit, so the current text stays in the history too.
struct HistoryView: View {
    @Environment(SyncEngine.self) private var engine
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme
    let noteID: String

    @State private var revisions: [Revision] = []
    @State private var selected: Revision?
    @State private var loading = true
    @State private var error: String?
    @State private var source = false
    @State private var confirmRestore = false
    @State private var preview: EditorHost?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(L.history)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L.close) { dismiss() } }
                    if let selected, selected.body != nil {
                        ToolbarItem(placement: .primaryAction) {
                            Picker(L.show, selection: $source) {
                                Text(L.rendered).tag(false)
                                Text(L.source).tag(true)
                            }
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                        if selected.rev != revisions.first?.rev {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L.restoreVersion) { confirmRestore = true }
                            }
                        }
                    }
                }
                .confirmationDialog(restorePrompt, isPresented: $confirmRestore, titleVisibility: .visible) {
                    Button(L.restoreVersion) { restore() }
                }
        }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 520)
        #endif
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        if library.api == nil {
            ContentUnavailableView(L.localNoHistory, systemImage: "clock.arrow.circlepath",
                                   description: Text(L.localNoHistoryHint))
        } else if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            ContentUnavailableView {
                Label(L.historyLoadFailed, systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button(L.retry) { Task { await load() } }
            }
        } else if revisions.isEmpty {
            ContentUnavailableView(L.noHistory, systemImage: "clock.arrow.circlepath",
                                   description: Text(L.noHistoryHint))
        } else if sizeClass == .compact {
            VStack(spacing: 0) {
                list.frame(height: 200)
                Divider()
                detail
            }
        } else {
            HStack(spacing: 0) {
                list.frame(width: 260)
                Divider()
                detail
            }
        }
    }

    private var list: some View {
        List(selection: Binding(get: { selected?.rev }, set: { rev in
            if let r = revisions.first(where: { $0.rev == rev }) { Task { await pick(r) } }
        })) {
            ForEach(Array(revisions.enumerated()), id: \.element.rev) { i, r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.time(r.createdAt)).font(.callout.weight(.medium))
                    Text([i == 0 ? L.currentVersion : nil, r.device.isEmpty ? "web" : r.device, r.size.byteText]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(r.rev as Int64?)
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder private var detail: some View {
        if let selected, let body = selected.body {
            VStack(alignment: .leading, spacing: 0) {
                Text(selected.title.isEmpty ? L.untitled : selected.title)
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .lineLimit(2)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                if source {
                    ScrollView {
                        Text(body)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                    }
                } else if let preview {
                    MarkdownEditor(host: preview)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var restorePrompt: String {
        guard let selected else { return "" }
        return L.restorePrompt(Self.time(selected.createdAt))
    }

    private func load() async {
        guard let api = library.api else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            revisions = try await api.history(noteID)
            if let first = revisions.first { await pick(first) }
        } catch let e as APIError where e.status == 404 {
            // A note never pushed has no history yet.
            revisions = []
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func pick(_ r: Revision) async {
        selected = r
        guard let api = library.api else { return }
        do {
            let full = try await api.revision(noteID, r.rev)
            guard selected?.rev == r.rev else { return }
            selected = full
            if preview == nil {
                let host = EditorHost(account: library.account, engine: engine, readonly: true)
                host.setTheme(dark: colorScheme == .dark)
                preview = host
            }
            preview?.show(full.body ?? "")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func restore() {
        guard let selected, let body = selected.body else { return }
        engine.updateNote(noteID, .init(title: selected.title, body: body))
        dismiss()
    }

    static func time(_ ms: Millis) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000).formatted(.dateTime.year().month(.defaultDigits).day().hour().minute().locale(L10n.s.locale))
    }
}
