import Foundation

/// Wiki links (`[[Title]]`, `[[Title|alias]]`, `[[Title#heading]]`), note
/// links (`ivy://note/<id>`) and attachment references (`ivy://res/<id>`),
/// computed locally so backlinks work offline (guide 9.2). A port of the web
/// client's `packages/core/src/markdown/links.ts`.
public enum Links {
    static var wiki: Regex<(Substring, Substring)> { /\[\[([^\[\]\n]+?)\]\]/ }
    static var noteRef: Regex<(Substring, Substring)> { /ivy:\/\/note\/([A-Za-z0-9_-]{8,64})/ }
    static var resRef: Regex<(Substring, Substring)> { /ivy:\/\/res\/([A-Za-z0-9_-]{8,64})/ }

    /// Trimmed, runs of white space as one space, lower case.
    public static func normalizeTitle(_ t: String) -> String {
        t.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// The body without fenced code blocks and inline code: links there are
    /// examples, not links.
    public static func stripCode(_ body: String) -> String {
        var out: [Substring] = []
        // Lines of an open fence; kept if it never closes, as the web's regex does.
        var fenced: [Substring]?
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if fenced != nil {
                if t == "```" || t == "~~~" { fenced = nil } else { fenced!.append(line) }
                continue
            }
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                fenced = [line]
                continue
            }
            out.append(line)
        }
        if let open = fenced { out += open }
        return out.joined(separator: "\n").replacing(/`[^`\n]*`/, with: "")
    }

    public struct WikiLink: Equatable, Sendable {
        public var target: String
        public var alias: String?
        public var heading: String?
    }

    /// The inside of `[[…]]`: target first, then `|alias`, `#heading`.
    public static func parseWiki(_ inner: String) -> WikiLink {
        var target = Substring(inner)
        var alias: String?
        var heading: String?
        if let bar = target.firstIndex(of: "|") {
            alias = target[target.index(after: bar)...].trimmingCharacters(in: .whitespaces)
            target = target[..<bar]
        }
        if let hash = target.firstIndex(of: "#") {
            heading = target[target.index(after: hash)...].trimmingCharacters(in: .whitespaces)
            target = target[..<hash]
        }
        return WikiLink(target: target.trimmingCharacters(in: .whitespaces), alias: alias, heading: heading)
    }

    /// Distinct normalized link targets of a body.
    public static func wikiTargets(_ body: String) -> Set<String> {
        var out = Set<String>()
        for m in stripCode(body).matches(of: wiki) {
            let key = normalizeTitle(parseWiki(String(m.1)).target)
            if !key.isEmpty { out.insert(key) }
        }
        return out
    }

    public static func noteRefs(_ body: String) -> Set<String> {
        Set(stripCode(body).matches(of: noteRef).map { String($0.1) })
    }

    /// Attachments a body uses. Unlike links these count inside code too, as
    /// the server counts them.
    public static func resourceRefs(_ body: String) -> [String] {
        var seen = Set<String>()
        return body.matches(of: resRef).map { String($0.1) }.filter { seen.insert($0).inserted }
    }

    /// The notes that link to `id`: by `[[title]]` (the most recently updated
    /// note of that title wins) or by `ivy://note/<id>`. Notes in the trash
    /// and the note itself are left out. Most recently updated first.
    public static func backlinks(to id: String, in notes: some Collection<Note>) -> [Note] {
        let live = notes.filter { !$0.isTrashed && !$0.deleted }
        guard let target = live.first(where: { $0.id == id }) else { return [] }
        let key = normalizeTitle(target.title)
        // Whether `[[title]]` resolves to this note rather than a namesake.
        var ownsTitle = false
        if !key.isEmpty {
            let winner = live.filter { normalizeTitle($0.title) == key }.max { a, b in
                a.updatedAt != b.updatedAt ? a.updatedAt < b.updatedAt : a.id > b.id
            }
            ownsTitle = winner?.id == id
        }
        return live.filter { n in
            guard n.id != id else { return false }
            if n.body.contains("ivy://note/\(id)"), noteRefs(n.body).contains(id) { return true }
            return ownsTitle && n.body.contains("[[") && wikiTargets(n.body).contains(key)
        }.sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }
    }

    /// The line around a link to `title` in `body`, links shown as their
    /// text, for a backlink's preview.
    public static func context(in body: String, linkingTo title: String, noteID: String = "", max: Int = 90) -> String {
        let key = normalizeTitle(title)
        for line in body.split(separator: "\n") {
            let hit = line.matches(of: wiki).contains { !key.isEmpty && normalizeTitle(parseWiki(String($0.1)).target) == key }
                || (!noteID.isEmpty && line.contains("ivy://note/\(noteID)"))
            guard hit else { continue }
            var text = String(line).replacing(wiki) { m in
                let w = parseWiki(String(m.1))
                return w.alias.flatMap { $0.isEmpty ? nil : $0 } ?? w.target
            }
            // `[text](ivy://note/…)` reads as its text.
            text = text.replacing(/\[([^\]]*)\]\(ivy:\/\/note\/[A-Za-z0-9_-]{8,64}\)/) { String($0.1) }
            text = String(text.drop(while: { " \t>#*-+0123456789.)[]x".contains($0) })).trimmingCharacters(in: .whitespaces)
            return text.count > max ? String(text.prefix(max)) + "…" : text
        }
        return ""
    }
}
