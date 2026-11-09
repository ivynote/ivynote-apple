import IvynoteKit
import SwiftUI

/// The agenda (guide 11.8): open to-dos with a 📅 date across the library,
/// overdue first. Checking one off writes the note as the editor would; a
/// tap opens the note at the task.
struct AgendaView: View {
    @Environment(SyncEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    /// Opens a note at a 0-based line.
    let open: (_ id: String, _ line: Int) -> Void

    private var items: [Tasks.AgendaItem] { Tasks.agenda(engine.notes.values) }
    private var anyProtected: Bool {
        engine.notes.values.contains { !$0.deleted && !$0.isTrashed && NoteLock.isEncrypted($0.body) }
    }

    private func group(_ days: Int) -> String {
        days < 0 ? L.agendaOverdue : days == 0 ? L.agendaToday : L.agendaLater
    }

    var body: some View {
        NavigationStack {
            let list = items
            let groups = [L.agendaOverdue, L.agendaToday, L.agendaLater].filter { g in list.contains { group($0.days) == g } }
            List {
                if list.isEmpty {
                    ContentUnavailableView(L.agendaEmpty, systemImage: "calendar", description: Text(L.agendaEmptyHint))
                }
                ForEach(groups, id: \.self) { g in
                    Section(g) {
                        ForEach(list.filter { group($0.days) == g }.map { ("\($0.noteId):\($0.task.line)", $0) }, id: \.0) { pair in
                            AgendaRow(item: pair.1, toggle: { toggle(pair.1) }, open: { open(pair.1.noteId, pair.1.task.line) })
                        }
                    }
                }
                if anyProtected {
                    Text(L.agendaProtectedHint).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L.agenda)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L.done) { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func toggle(_ item: Tasks.AgendaItem) {
        guard let note = engine.notes[item.noteId] else { return }
        // Only if the line is still the task shown.
        let lines = note.body.split(separator: "\n", omittingEmptySubsequences: false)
        guard item.task.line < lines.count, String(lines[item.task.line]) == item.task.raw else { return }
        engine.updateNote(note.id, .init(body: Tasks.toggle(note.body, line: item.task.line)))
    }
}

private struct AgendaRow: View {
    let item: Tasks.AgendaItem
    let toggle: () -> Void
    let open: () -> Void

    private var dateText: String {
        guard let due = item.task.due, let day = due.day() else { return "" }
        let date = day.formatted(.dateTime.month().day().weekday(.abbreviated).locale(L.locale))
        return due.hour != nil ? "\(date) \(due.timeText)" : date
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: toggle) {
                Image(systemName: "circle").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.task.text.isEmpty ? L.untitled : item.task.text).foregroundStyle(.primary).lineLimit(2)
                    Text("\(dateText) · \(item.noteTitle.isEmpty ? L.untitled : item.noteTitle)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(L.daysLeft(item.days))
                .font(.caption)
                .foregroundStyle(item.days < 0 ? Color.red : item.days == 0 ? Color.accentColor : Color.secondary)
        }
    }
}
