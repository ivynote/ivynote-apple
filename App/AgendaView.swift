import IvynoteKit
import SwiftUI

/// The agenda (guide 11.8): open to-dos with a 📅 date across the library as
/// a tree by day — overdue, each day of the coming week, then by month — the
/// same branches as the web. Checking one off writes the note as the editor
/// would; a tap opens the note at the task.
struct AgendaView: View {
    @Environment(SyncEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    /// Opens a note at a 0-based line.
    let open: (_ id: String, _ line: Int) -> Void

    /// Folded and unfolded branches, remembered on this device: for branches
    /// open by default a stored key means folded, for the others unfolded.
    @AppStorage("ivy.agenda.toggled") private var toggledRaw = ""

    private var toggled: Set<String> { Set(toggledRaw.split(separator: "\n").map(String.init)) }

    private func isOpen(_ n: Tasks.AgendaNode) -> Bool { n.openByDefault != toggled.contains(n.key) }

    private func binding(_ n: Tasks.AgendaNode, live: Set<String>) -> Binding<Bool> {
        Binding(
            get: { isOpen(n) },
            set: { open in
                var keys = toggled.filter { live.contains($0) }
                if open == n.openByDefault { keys.remove(n.key) } else { keys.insert(n.key) }
                toggledRaw = keys.sorted().joined(separator: "\n")
            }
        )
    }

    private var anyProtected: Bool {
        engine.notes.values.contains { !$0.deleted && !$0.isTrashed && NoteLock.isEncrypted($0.body) }
    }

    var body: some View {
        NavigationStack {
            let tree = Tasks.agendaTree(Tasks.agenda(engine.notes.values))
            let live = Set(tree.map(\.key))
            let today = Tasks.Due(date: Date())
            List {
                if tree.isEmpty {
                    ContentUnavailableView(L.agendaEmpty, systemImage: "calendar", description: Text(L.agendaEmptyHint))
                }
                ForEach(tree) { node in
                    Section(isExpanded: binding(node, live: live)) {
                        ForEach(node.items.map { ("\($0.noteId):\($0.task.line)", $0) }, id: \.0) { pair in
                            AgendaRow(item: pair.1, showsDay: node.kind == .overdue || node.kind == .month,
                                      toggle: { toggle(pair.1) }, open: { open(pair.1.noteId, pair.1.task.line) })
                        }
                    } header: {
                        HStack {
                            Label(label(node, today: today), systemImage: node.kind == .overdue ? "exclamationmark.circle" : "calendar")
                                .foregroundStyle(node.kind == .overdue ? Color.red : node.kind == .today ? Color.accentColor : Color.primary)
                            Spacer()
                            Text("\(node.items.count)").foregroundStyle(.secondary)
                        }
                    }
                }
                if anyProtected {
                    Text(L.agendaProtectedHint).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
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

    private func label(_ n: Tasks.AgendaNode, today: Tasks.Due) -> String {
        switch n.kind {
        case .overdue: return L.agendaOverdue
        case .month: return n.date.map { L.agendaMonth($0, today: today) } ?? ""
        default: return n.date.map { L.agendaDay($0, today: today) } ?? ""
        }
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
    /// Branches of single days say the day already; the others say it per task.
    let showsDay: Bool
    let toggle: () -> Void
    let open: () -> Void

    private var whenText: String {
        guard let due = item.task.due else { return "" }
        guard showsDay else { return due.timeText }
        let day = L.locale.language.languageCode?.identifier == "zh" ? "\(due.month)月\(due.day)日" : "\(due.month)/\(due.day)"
        return due.hour != nil ? "\(day) \(due.timeText)" : day
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: toggle) {
                Image(systemName: "circle").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.task.text.isEmpty ? L.untitled : item.task.text).foregroundStyle(.primary).lineLimit(1)
                    Text(item.noteTitle.isEmpty ? L.untitled : item.noteTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if item.task.repeat != nil { Text("🔁").font(.caption2) }
            Text(whenText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(item.days < 0 ? Color.red : Color.secondary)
        }
    }
}
