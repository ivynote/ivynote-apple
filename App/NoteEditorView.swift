import IvynoteKit
import SwiftUI

/// Plain Markdown editing: a title field and the body as text. Every change
/// is saved locally at once and synced in the background; there is no save
/// button (guide 3.2). The CodeMirror live-preview editor comes later.
struct NoteEditorView: View {
    @Environment(SyncEngine.self) private var engine
    let noteID: String

    @FocusState private var bodyFocused: Bool

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
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                    .onSubmit { bodyFocused = true }
                    .disabled(note.isTrashed)
                Divider().padding(.horizontal, 16)
                TextEditor(text: bodyText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 11)
                    .focused($bodyFocused)
                    .disabled(note.isTrashed)
                    #if os(iOS)
                    .textInputAutocapitalization(.sentences)
                    #endif
            }
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
            .onAppear { if note.body.isEmpty && note.title.isEmpty && !note.isTrashed { bodyFocused = true } }
        }
    }

    private var title: Binding<String> {
        Binding(get: { engine.notes[noteID]?.title ?? "" },
                set: { engine.updateNote(noteID, .init(title: String($0.replacingOccurrences(of: "\n", with: " ").prefix(300)))) })
    }

    private var bodyText: Binding<String> {
        Binding(get: { engine.notes[noteID]?.body ?? "" },
                set: { engine.updateNote(noteID, .init(body: $0)) })
    }
}
