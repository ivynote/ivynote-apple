import IvynoteKit
import SwiftUI

/// A note: the title as a native field, the body in the web client's
/// CodeMirror editor with live preview. Every change is saved locally at once
/// and synced in the background; there is no save button (guide 3.2).
struct NoteEditorView: View {
    @Environment(SyncEngine.self) private var engine
    @Environment(EditorHost.self) private var host
    @Environment(\.colorScheme) private var colorScheme
    let noteID: String

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
                TextField("无标题", text: title, axis: .vertical)
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                    .onSubmit { host.focus() }
                    .disabled(note.isTrashed)
                MarkdownEditor(host: host)
            }
            // The page's --surface, so the title and the body are one sheet.
            .background(colorScheme == .dark ? Color(red: 25 / 255, green: 27 / 255, blue: 30 / 255) : .white)
            #if os(iOS)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if host.focused && !note.isTrashed { FormatBar(host: host) }
            }
            #endif
            .navigationTitle(displayTitle(note))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if !note.isTrashed {
                    Menu("更多", systemImage: "ellipsis.circle") {
                        Button(note.pinned ? "取消置顶" : "置顶", systemImage: note.pinned ? "pin.slash" : "pin") {
                            engine.updateNote(noteID, .init(pinned: !note.pinned))
                        }
                        MoveToFolderMenu(note: note)
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
            }
            .onChange(of: note.body) { _, body in host.bodyChanged(noteID, body) }
            .onChange(of: note.isTrashed) { _, trashed in host.setReadonly(trashed) }
            .onChange(of: colorScheme) { _, scheme in host.setTheme(dark: scheme == .dark) }
        }
    }

    private var title: Binding<String> {
        Binding(get: { engine.notes[noteID]?.title ?? "" },
                set: { engine.updateNote(noteID, .init(title: String($0.replacingOccurrences(of: "\n", with: " ").prefix(300)))) })
    }
}

#if os(iOS)
/// The phone's insert bar (guide 3.2): formatting the soft keyboard lacks.
struct FormatBar: View {
    let host: EditorHost

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
