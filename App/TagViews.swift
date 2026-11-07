import IvynoteKit
import SwiftUI

/// Tag colors, as the web's `tagColor()`: a chosen one, or one derived
/// from the name so that a tag keeps its color everywhere.
enum TagPalette {
    static let names = ["green", "blue", "amber", "pink", "purple", "gray"]

    static func label(_ name: String) -> String {
        L10n.s.tagColor(name)
    }

    static func name(for tag: Tag) -> String {
        if names.contains(tag.color) { return tag.color }
        var h: UInt32 = 0
        for scalar in tag.name.unicodeScalars { h = h &* 31 &+ scalar.value }
        return names[Int(h % UInt32(names.count))]
    }

    static func color(_ name: String) -> Color {
        switch name {
        case "green": Color(red: 0.24, green: 0.55, blue: 0.38)
        case "blue": Color(red: 0.25, green: 0.47, blue: 0.78)
        case "amber": Color(red: 0.78, green: 0.53, blue: 0.13)
        case "pink": Color(red: 0.80, green: 0.33, blue: 0.53)
        case "purple": Color(red: 0.52, green: 0.38, blue: 0.78)
        default: Color(red: 0.45, green: 0.48, blue: 0.51)
        }
    }

    static func color(for tag: Tag) -> Color {
        // A hex color written by another client is shown as it is.
        if tag.color.hasPrefix("#"), tag.color.count == 7, let v = Int(tag.color.dropFirst(), radix: 16) {
            return Color(red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255)
        }
        return color(name(for: tag))
    }
}

/// The line under the title (guide 11.3): when it changed, how long it is,
/// its tags and the way to add one.
struct NoteMetaBar: View {
    @Environment(SyncEngine.self) private var engine
    let note: Note
    var uploading = 0

    @State private var picking = false
    @State private var editing: Tag?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(Self.time(note.updatedAt))
                Text(L.words(WordCount.count(note.body).formatted(.number.locale(L.locale))))
                if uploading > 0 {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text(L.uploading)
                    }
                }
                ForEach(noteTags) { tag in
                    if note.isTrashed {
                        TagChip(tag: tag)
                    } else {
                        Menu {
                            Button(L.removeFromNote, systemImage: "minus.circle") { remove(tag) }
                            Button(L.editTagEllipsis, systemImage: "pencil") { editing = tag }
                        } label: {
                            TagChip(tag: tag)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }
                if !note.isTrashed {
                    Button { picking = true } label: {
                        Label(L.tags, systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L.addTag)
                    .popover(isPresented: $picking) {
                        TagPicker(noteID: note.id)
                            .frame(minWidth: 280, minHeight: 320)
                            .presentationCompactAdaptation(.sheet)
                            .presentationDetents([.medium, .large])
                    }
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
        }
        .sheet(item: $editing) { tag in TagEditor(tagID: tag.id) }
    }

    private var noteTags: [Tag] {
        note.tags.compactMap { engine.tags[$0] }
    }

    private func remove(_ tag: Tag) {
        engine.updateNote(note.id, .init(tags: note.tags.filter { $0 != tag.id }))
    }

    /// Today `16:20`, yesterday, the weekday within 6 days, `10月29日` this
    /// year, `2025年3月1日` before (guide 11.7), each with the time.
    static func time(_ ms: Millis, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let cal = Calendar.current
        let clock = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(L10n.s.locale))
        if cal.isDateInToday(date) { return clock }
        if cal.isDateInYesterday(date) { return L10n.s.yesterday(clock) }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day ?? 99
        if days < 7 && days > 0 { return "\(date.formatted(.dateTime.weekday(.wide).locale(L10n.s.locale))) \(clock)" }
        if cal.isDate(date, equalTo: now, toGranularity: .year) {
            return "\(date.formatted(.dateTime.month(.defaultDigits).day().locale(L10n.s.locale))) \(clock)"
        }
        return date.formatted(.dateTime.year().month(.defaultDigits).day().locale(L10n.s.locale))
    }
}

struct TagChip: View {
    let tag: Tag

    var body: some View {
        let color = TagPalette.color(for: tag)
        Text("#\(tag.name)")
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
    }
}

/// Adds tags to a note and takes them off: search, tick, or create.
struct TagPicker: View {
    @Environment(SyncEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let noteID: String

    @State private var query = ""

    static let maxPerNote = 50

    var body: some View {
        NavigationStack {
            List {
                let q = String(query.trimmingCharacters(in: .whitespaces).trimmingPrefix("#"))
                if !q.isEmpty && engine.tag(named: q) == nil {
                    Button {
                        create(q)
                    } label: {
                        Label(L.createTag(q), systemImage: "plus")
                    }
                    .disabled(full || q.count > 50)
                }
                ForEach(matches(q)) { tag in
                    Button { toggle(tag) } label: {
                        HStack {
                            Circle().fill(TagPalette.color(for: tag)).frame(width: 8, height: 8)
                            Text(tag.name).foregroundStyle(.primary)
                            Spacer()
                            if selected.contains(tag.id) {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(full && !selected.contains(tag.id))
                }
                if full {
                    Text(L.maxTags(Self.maxPerNote)).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .overlay {
                if engine.tags.isEmpty && query.isEmpty {
                    ContentUnavailableView(L.noTags, systemImage: "tag", description: Text(L.noTagsHint))
                }
            }
            .searchable(text: $query, placement: .automatic, prompt: L.searchOrCreateTag)
            .onSubmit(of: .search) {
                let q = String(query.trimmingCharacters(in: .whitespaces).trimmingPrefix("#"))
                guard !q.isEmpty else { return }
                if let tag = engine.tag(named: q) {
                    if !selected.contains(tag.id) { toggle(tag) }
                } else {
                    create(q)
                }
                query = ""
            }
            .navigationTitle(L.tags)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L.done) { dismiss() } }
            }
        }
    }

    private var selected: [String] { engine.notes[noteID]?.tags ?? [] }
    private var full: Bool { selected.count >= Self.maxPerNote }

    private func matches(_ q: String) -> [Tag] {
        engine.tags.values
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
            .sorted { a, b in
                // The note's own tags first, then by name.
                let sa = selected.contains(a.id), sb = selected.contains(b.id)
                if sa != sb { return sa }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    private func toggle(_ tag: Tag) {
        var tags = selected
        if let i = tags.firstIndex(of: tag.id) { tags.remove(at: i) } else if tags.count < Self.maxPerNote { tags.append(tag.id) }
        engine.updateNote(noteID, .init(tags: tags))
    }

    private func create(_ name: String) {
        guard !full else { return }
        let tag = engine.createTag(name: String(name.prefix(50)))
        engine.updateNote(noteID, .init(tags: selected + [tag.id]))
        query = ""
    }
}

/// Renames a tag, picks its color, or deletes it (from every note).
struct TagEditor: View {
    @Environment(SyncEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let tagID: String

    @State private var name = ""
    @State private var color = ""
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L.name) {
                    TextField(L.tagName, text: $name)
                        .onSubmit(save)
                    if let error = nameError { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                Section(L.color) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 12) {
                        swatch("")
                        ForEach(TagPalette.names, id: \.self) { swatch($0) }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Button(L.deleteTag, role: .destructive) { confirmDelete = true }
                } footer: {
                    Text(L.deleteTagMessage(usage))
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L.editTag)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L.cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(L.save, action: save).disabled(nameError != nil) }
            }
            .confirmationDialog(L.deleteTagTitle(name), isPresented: $confirmDelete) {
                Button(L.delete, role: .destructive) {
                    engine.deleteTag(tagID)
                    dismiss()
                }
            }
            .onAppear {
                guard let tag = engine.tags[tagID] else { return dismiss() }
                name = tag.name
                color = tag.color
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 360)
        #endif
    }

    private var usage: Int { engine.notes.values.filter { $0.tags.contains(tagID) }.count }

    private var clean: String { String(name.trimmingCharacters(in: .whitespaces).trimmingPrefix("#")) }

    private var nameError: String? {
        if clean.isEmpty { return L.nameEmpty }
        if clean.count > 50 { return L.nameTooLong }
        if let other = engine.tag(named: clean), other.id != tagID { return L.tagExists }
        return nil
    }

    private func swatch(_ value: String) -> some View {
        let preview = Tag(id: tagID, name: clean.isEmpty ? "tag" : clean, color: value, createdAt: 0, updatedAt: 0)
        return Button { color = value } label: {
            ZStack {
                Circle().fill(TagPalette.color(for: preview)).frame(width: 28, height: 28)
                if value.isEmpty { Text("A").font(.caption.bold()).foregroundStyle(.white) }
                if color == value || (!TagPalette.names.contains(color) && value.isEmpty) {
                    Circle().strokeBorder(.primary, lineWidth: 2).frame(width: 36, height: 36)
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(TagPalette.label(value))
    }

    private func save() {
        guard nameError == nil else { return }
        engine.updateTag(tagID, name: clean, color: color)
        dismiss()
    }
}
