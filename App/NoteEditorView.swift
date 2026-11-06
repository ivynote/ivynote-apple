import IvynoteKit
import SwiftUI

/// A note: the title in the navigation bar (tap it for 重命名), the body in the web client's
/// CodeMirror editor with live preview. Every change is saved locally at once
/// and synced in the background; there is no save button (guide 3.2).
struct NoteEditorView: View {
    @Environment(SyncEngine.self) private var engine
    @Environment(EditorHost.self) private var host
    @Environment(Library.self) private var library
    @Environment(\.colorScheme) private var colorScheme
    let noteID: String

    @State private var renaming = false
    @State private var titleDraft = ""
    @State private var pickers = AttachmentPickerState()
    @State private var inserter = AttachmentInserter()
    @State private var sharing = false
    @State private var showHistory = false

    var body: some View {
        if let note = engine.notes[noteID] {
            VStack(alignment: .leading, spacing: 0) {
                if note.isTrashed {
                    HStack {
                        Label("这篇笔记在回收站中", systemImage: "trash")
                        Spacer()
                        Button("恢复") { engine.updateNote(noteID, .init(trashed: false)) }
                    }
                    .font(.callout)
                    .padding(12)
                    .background(.orange.opacity(0.12))
                }
                NoteMetaBar(note: note, uploading: inserter.busy)
                MarkdownEditor(host: host)
            }
            // The page's --surface, so the title and the body are one sheet.
            .background(colorScheme == .dark ? Color(red: 25 / 255, green: 27 / 255, blue: 30 / 255) : .white)
            #if os(iOS)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if host.focused && !note.isTrashed { FormatBar(host: host, pickers: $pickers) }
            }
            #endif
            .modifier(AttachmentPickers(state: $pickers) { files in add(files) })
            .overlay(alignment: .bottom) { NoticeToast(text: $inserter.notice) }
            .sheet(isPresented: $sharing) { ShareView(noteID: noteID) }
            .sheet(isPresented: $showHistory) { HistoryView(noteID: noteID) }
            // One title, in the bar: editable there unless the note is in the trash.
            .navigationTitle(displayTitle(note))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbarTitleMenu {
                if !note.isTrashed {
                    Button("重命名", systemImage: "pencil") {
                        titleDraft = note.title
                        renaming = true
                    }
                }
            }
            .alert("重命名笔记", isPresented: $renaming) {
                TextField("无标题", text: $titleDraft)
                Button("取消", role: .cancel) {}
                Button("保存") { rename() }
            }
            .modifier(NoteOutline(text: note.body))
            .toolbar {
                if !note.isTrashed {
                    InsertMenu(pickers: $pickers)
                    Button("分享", systemImage: "square.and.arrow.up") { sharing = true }
                        .help("分享与导出")
                    Menu("更多", systemImage: "ellipsis.circle") {
                        Button(note.pinned ? "取消置顶" : "置顶", systemImage: note.pinned ? "pin.slash" : "pin") {
                            engine.updateNote(noteID, .init(pinned: !note.pinned))
                        }
                        MoveToFolderMenu(note: note)
                        if !library.ref.isLocal {
                            Button("历史版本", systemImage: "clock.arrow.circlepath") { showHistory = true }
                        }
                        Divider()
                        Button("移到回收站", systemImage: "trash", role: .destructive) {
                            engine.updateNote(noteID, .init(trashed: true))
                        }
                    }
                }
            }
            .onAppear {
                host.setTheme(dark: colorScheme == .dark)
                host.open(note, focus: note.body.isEmpty && note.title.isEmpty && !note.isTrashed)
                let inserter = inserter, engine = engine, host = host, id = noteID
                host.onFiles = { [weak host] files in
                    guard let host else { return }
                    inserter.add(files.map { .init(name: $0.name, mime: $0.mime, data: $0.data) }, to: id, engine: engine, host: host)
                }
            }
            // Backlinks change with this title and with other notes, which
            // change here by sync (or while this note is not open).
            .task(id: BacklinkKey(title: note.title, trashed: note.isTrashed, cursor: engine.cursor, count: engine.notes.count)) {
                guard !note.isTrashed else { return host.setBacklinks([]) }
                let links = Links.backlinks(to: noteID, in: engine.notes.values)
                host.setBacklinks(links.map { n in
                    (id: n.id, title: displayTitle(n), context: Links.context(in: n.body, linkingTo: note.title, noteID: noteID))
                })
            }
            .onChange(of: note.body) { _, body in host.bodyChanged(noteID, body) }
            .onChange(of: note.isTrashed) { _, trashed in host.setReadonly(trashed) }
            .onChange(of: colorScheme) { _, scheme in host.setTheme(dark: scheme == .dark) }
        }
    }

    private func add(_ files: [AttachmentInserter.File]) {
        inserter.add(files, to: noteID, engine: engine, host: host)
    }

    private struct BacklinkKey: Equatable {
        let title: String
        let trashed: Bool
        let cursor: Int64
        let count: Int
    }

    private func rename() {
        let v = String(titleDraft.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces).prefix(300))
        if v != engine.notes[noteID]?.title { engine.updateNote(noteID, .init(title: v)) }
    }
}

/// The outline of a note and its toolbar switch: a column beside the note
/// on the Mac and iPad (kept open across notes), a sheet on iPhone (closed
/// again after each jump).
struct NoteOutline: ViewModifier {
    @Environment(EditorHost.self) private var host
    @Environment(\.horizontalSizeClass) private var sizeClass
    let text: String

    @AppStorage("ivy.outline") private var pinned = false
    @State private var sheet = false

    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    func body(content: Content) -> some View {
        let shown = compact ? $sheet : $pinned
        content
            .inspector(isPresented: shown) {
                // Built only while presented; not gated on `shown`, which turns
                // false while the sheet is still sliding away.
                let headings = Outline.headings(in: text)
                OutlineView(headings: headings, current: Outline.current(in: headings, top: host.topLine)) { line in
                    host.scrollToLine(line)
                    if compact { sheet = false }
                } onClose: {
                    shown.wrappedValue = false
                }
                .inspectorColumnWidth(min: 200, ideal: 248, max: 340)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(shown.wrappedValue ? "隐藏大纲" : "显示大纲", systemImage: "list.bullet.indent") {
                        withAnimation(.snappy) { shown.wrappedValue.toggle() }
                    }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .help(shown.wrappedValue ? "隐藏大纲 ⇧⌘O" : "显示大纲 ⇧⌘O")
                }
            }
    }
}

/// Sizes of the outline: compact on the Mac, finger-sized on iPhone and iPad.
private enum OutlineMetrics {
    #if os(iOS)
    static let font: CGFloat = 15
    static let rowPadding: CGFloat = 9
    static let guide: CGFloat = 16
    #else
    static let font: CGFloat = 13
    static let rowPadding: CGFloat = 5
    static let guide: CGFloat = 14
    #endif
}

/// The note's headings as a quiet table of contents: nesting drawn with thin
/// guide lines, the section in view marked, a tap scrolls the editor there.
struct OutlineView: View {
    let headings: [Heading]
    /// The line of the heading whose section is in view.
    let current: Int?
    let onPick: (Int) -> Void
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if headings.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // A heading of its own: a navigation title here would replace the
    // note's in the bar.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("大纲")
                .font(.system(size: OutlineMetrics.font, weight: .semibold))
            if !headings.isEmpty {
                Text("\(headings.count)")
                    .font(.system(size: OutlineMetrics.font - 2).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: OutlineMetrics.font - 3, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("隐藏大纲")
                .accessibilityLabel("隐藏大纲")
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有标题")
                .font(.system(size: OutlineMetrics.font, weight: .medium))
                .foregroundStyle(.secondary)
            Text("以 # 开头的行会出现在这里。")
                .font(.system(size: OutlineMetrics.font - 1))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }

    private var list: some View {
        let top = headings.map(\.level).min() ?? 1
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(headings) { h in
                        OutlineRow(heading: h, depth: min(h.level - top, 4), active: h.line == current) {
                            onPick(h.line)
                        }
                        .id(h.line)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .onChange(of: current) { _, line in
                guard let line else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(line, anchor: .center) }
            }
        }
    }
}

private struct OutlineRow: View {
    let heading: Heading
    /// Levels below the outline's top level, drawn as guide lines.
    let depth: Int
    let active: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                ForEach(0..<depth, id: \.self) { _ in
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 1)
                        .frame(width: OutlineMetrics.guide)
                }
                Text(heading.text)
                    .font(.system(size: OutlineMetrics.font, weight: depth == 0 ? .medium : .regular))
                    .foregroundStyle(active ? AnyShapeStyle(.tint) : depth == 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.vertical, OutlineMetrics.rowPadding)
                    .padding(.leading, 10)
                    .padding(.trailing, 8)
                Spacer(minLength: 0)
            }
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.primary.opacity(hovered ? 0.06 : 0)))
            }
            .overlay(alignment: .leading) {
                // The marker of the section in view.
                if active {
                    Capsule()
                        .fill(.tint)
                        .frame(width: 3, height: 14)
                        .padding(.leading, CGFloat(depth) * OutlineMetrics.guide + 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.2), value: active)
        .help(heading.text)
    }
}

#if os(iOS)
/// The phone's insert bar (guide 3.2): formatting the soft keyboard lacks.
struct FormatBar: View {
    let host: EditorHost
    @Binding var pickers: AttachmentPickerState

    private let items: [(String, String, String)] = [
        ("h1", "number", "标题"),
        ("bold", "bold", "加粗"),
        ("italic", "italic", "斜体"),
        ("task", "checklist", "待办"),
        ("list", "list.bullet", "列表"),
        ("ordered", "list.number", "编号"),
        ("quote", "text.quote", "引用"),
        ("code", "chevron.left.forwardslash.chevron.right", "代码"),
        ("wiki", "link.badge.plus", "双链"),
        ("link", "link", "链接"),
        ("strike", "strikethrough", "删除线"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(items, id: \.0) { item in
                        Button { host.command(item.0) } label: {
                            Image(systemName: item.1).frame(width: 40, height: 40)
                        }
                        .accessibilityLabel(item.2)
                    }
                    // Files (guide 3.2): photos, the camera, any file.
                    Button { pickers.photos = true } label: { Image(systemName: "photo").frame(width: 40, height: 40) }
                        .accessibilityLabel("图片")
                    if AttachmentPickerState.cameraAvailable {
                        Button { pickers.camera = true } label: { Image(systemName: "camera").frame(width: 40, height: 40) }
                            .accessibilityLabel("拍照")
                    }
                    Button { pickers.files = true } label: { Image(systemName: "paperclip").frame(width: 40, height: 40) }
                        .accessibilityLabel("附件")
                }
                .padding(.horizontal, 6)
            }
            Divider().frame(height: 24)
            Button { host.command("undo") } label: { Image(systemName: "arrow.uturn.backward").frame(width: 40, height: 40) }
                .accessibilityLabel("撤销")
            Button { host.command("blur") } label: { Image(systemName: "keyboard.chevron.compact.down").frame(width: 44, height: 40) }
                .accessibilityLabel("收起键盘")
        }
        .font(.system(size: 16))
        .tint(.primary)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
#endif
