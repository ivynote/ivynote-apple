import Foundation

/// Password-protected notes (guide 8.4): the body is one ```ivy-encrypted
/// fence, sealed by the editor page. The app never decrypts it; it keeps it
/// out of search, the agenda and reminders.
public enum NoteLock {
    public static func isEncrypted(_ body: String) -> Bool {
        let start = body.drop(while: { $0.isWhitespace })
        guard start.hasPrefix("```ivy-encrypted") else { return false }
        let end = body.reversed().drop(while: { $0.isWhitespace })
        // One fence: it opens the body and its closing line ends it.
        guard String(end.prefix(3)) == "```" else { return false }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        let fences = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        return fences.count == 2
    }
}

/// Tasks with dates (guide 9.4), as the web client's `markdown/tasks.ts`:
/// `- [ ] 交房租 📅 2026-11-15 09:00 🔁 every month`. Dates are local.
public enum Tasks {
    public struct Due: Equatable, Sendable {
        public var year: Int, month: Int, day: Int
        /// Hour and minute; nil for the whole day.
        public var hour: Int?, minute: Int?

        public var dateText: String { String(format: "%04d-%02d-%02d", year, month, day) }
        public var timeText: String { hour.map { String(format: "%02d:%02d", $0, minute ?? 0) } ?? "" }

        public func day(in calendar: Calendar = .current) -> Date? {
            calendar.date(from: DateComponents(year: year, month: month, day: day))
        }

        /// When it reminds: its time, or `allDay` on the day; nil when it does not.
        public func fireDate(allDay: (hour: Int, minute: Int)?, calendar: Calendar = .current) -> Date? {
            let h = hour ?? allDay?.hour
            let m = hour != nil ? (minute ?? 0) : allDay?.minute
            guard let h, let m else { return nil }
            return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: h, minute: m))
        }
    }

    public struct Repeat: Equatable, Sendable {
        public var every: Int
        public var unit: String
        public var text: String
    }

    public struct Task: Equatable, Sendable {
        public var line: Int
        public var text: String
        public var done: Bool
        public var due: Due?
        public var `repeat`: Repeat?
        public var raw: String
    }

    static func validDate(_ s: Substring) -> (Int, Int, Int)? {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let cal = Calendar(identifier: .gregorian)
        guard let d = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        let c = cal.dateComponents([.year, .month, .day], from: d)
        guard c.year == parts[0], c.month == parts[1], c.day == parts[2] else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    public static func parseRepeat(_ text: String) -> Repeat? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t == "every weekday" { return Repeat(every: 1, unit: "weekday", text: text.trimmingCharacters(in: .whitespaces)) }
        guard let m = t.wholeMatch(of: /every\s+(?:(\d{1,3})\s+)?(day|week|month|year)s?/) else { return nil }
        let n = m.1.flatMap { Int($0) } ?? 1
        guard n >= 1 else { return nil }
        return Repeat(every: n, unit: String(m.2), text: text.trimmingCharacters(in: .whitespaces))
    }

    nonisolated(unsafe) private static let taskLine = /^(\s*(?:[-*+]|\d+[.)])\s+\[)([ xX])(\]\s?)(.*)$/
    nonisolated(unsafe) private static let dueMark = /📅\s*(\d{4}-\d{2}-\d{2})(?:[ T](\d{1,2}):(\d{2}))?/
    nonisolated(unsafe) private static let doneMark = /\s*✅\s*(\d{4}-\d{2}-\d{2})/
    nonisolated(unsafe) private static let repeatMark = /🔁\s*([^📅✅⏳🛫➕⏫🔼🔽🔺⏬\n]*)/

    /// The task lines of a body, skipping code.
    public static func parse(_ body: String) -> [Task] {
        var out: [Task] = []
        var inFence = false
        for (i, line) in body.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            if inFence { continue }
            guard let m = line.wholeMatch(of: taskLine) else { continue }
            let rest = String(m.4)
            var due: Due?
            if let d = rest.firstMatch(of: dueMark), let ymd = validDate(d.1) {
                var hour: Int?
                var minute: Int?
                if let hs = d.2, let ms = d.3, let h = Int(hs), let mi = Int(ms), (0...23).contains(h), (0...59).contains(mi) {
                    hour = h
                    minute = mi
                }
                due = Due(year: ymd.0, month: ymd.1, day: ymd.2, hour: hour, minute: minute)
            }
            let rep = rest.firstMatch(of: repeatMark).flatMap { parseRepeat(String($0.1)) }
            var text = rest.replacing(dueMark, with: "")
            text = text.replacing(doneMark, with: "")
            text = text.replacing(repeatMark, with: "")
            text = text.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
            out.append(Task(line: i, text: text, done: m.2 != " ", due: due, repeat: rep, raw: String(line)))
        }
        return out
    }

    private static func live(_ n: Note) -> Bool {
        !n.deleted && n.trashedAt == 0 && n.body.contains("📅") && !NoteLock.isEncrypted(n.body)
    }

    public struct Reminder: Equatable, Sendable {
        public var key: String
        public var noteId: String
        public var noteTitle: String
        public var text: String
        public var line: Int
        public var at: Date
    }

    /// Reminders that fire in [from, to). `allDay` is when a task with a date
    /// but no time reminds; nil: such tasks do not remind.
    public static func reminders(_ notes: some Sequence<Note>, from: Date, to: Date, allDay: (hour: Int, minute: Int)?, calendar: Calendar = .current) -> [Reminder] {
        var out: [Reminder] = []
        for n in notes where live(n) {
            for t in parse(n.body) where !t.done {
                guard let due = t.due, let at = due.fireDate(allDay: allDay, calendar: calendar), at >= from, at < to else { continue }
                let key = "\(n.id):\(stableHash(t.text)):\(due.dateText)\(due.timeText)"
                out.append(Reminder(key: key, noteId: n.id, noteTitle: n.title, text: t.text, line: t.line, at: at))
            }
        }
        return out.sorted { $0.at < $1.at }
    }

    public struct AgendaItem: Equatable, Sendable {
        public var noteId: String
        public var noteTitle: String
        public var task: Task
        /// Days from today to the due date (negative when overdue).
        public var days: Int
    }

    /// Open dated tasks across notes, soonest first (overdue at the top).
    public static func agenda(_ notes: some Sequence<Note>, today: Date = Date(), calendar: Calendar = .current) -> [AgendaItem] {
        let start = calendar.startOfDay(for: today)
        var out: [AgendaItem] = []
        for n in notes where live(n) {
            for t in parse(n.body) where !t.done {
                guard let due = t.due, let day = due.day(in: calendar) else { continue }
                let days = calendar.dateComponents([.day], from: start, to: day).day ?? 0
                out.append(AgendaItem(noteId: n.id, noteTitle: n.title, task: t, days: days))
            }
        }
        return out.sorted { a, b in
            let ka = (a.task.due!.dateText, a.task.due!.hour.map { String(format: "%02d:%02d", $0, a.task.due!.minute ?? 0) } ?? "99:99")
            let kb = (b.task.due!.dateText, b.task.due!.hour.map { String(format: "%02d:%02d", $0, b.task.due!.minute ?? 0) } ?? "99:99")
            if ka != kb { return ka < kb }
            if a.noteTitle != b.noteTitle { return a.noteTitle < b.noteTitle }
            return a.task.line < b.task.line
        }
    }

    static func nextDate(_ due: Due, _ rule: Repeat, calendar: Calendar = Calendar(identifier: .gregorian)) -> Due {
        guard let day = due.day(in: calendar) else { return due }
        var next: Date?
        switch rule.unit {
        case "day": next = calendar.date(byAdding: .day, value: rule.every, to: day)
        case "week": next = calendar.date(byAdding: .day, value: 7 * rule.every, to: day)
        case "month": next = calendar.date(byAdding: .month, value: rule.every, to: day)
        case "year": next = calendar.date(byAdding: .year, value: rule.every, to: day)
        default:
            var d = calendar.date(byAdding: .day, value: 1, to: day)
            while let x = d, calendar.isDateInWeekend(x) { d = calendar.date(byAdding: .day, value: 1, to: x) }
            next = d
        }
        guard let n = next else { return due }
        let c = calendar.dateComponents([.year, .month, .day], from: n)
        return Due(year: c.year ?? due.year, month: c.month ?? due.month, day: c.day ?? due.day, hour: due.hour, minute: due.minute)
    }

    /// Checks or unchecks the task on a 0-based line, as the editor does: a
    /// dated task gets ✅ and the day, a repeating one its next occurrence on
    /// the line above.
    public static func toggle(_ body: String, line lineNo: Int, today: Date = Date(), calendar: Calendar = .current) -> String {
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lineNo >= 0, lineNo < lines.count, let m = lines[lineNo].wholeMatch(of: taskLine) else { return body }
        let open = String(m.1), close = String(m.3), rest = String(m.4)
        if m.2 != " " {
            var s = open + " " + close + rest.replacing(doneMark, with: "")
            while s.last == " " { s.removeLast() }
            lines[lineNo] = s
            return lines.joined(separator: "\n")
        }
        guard let t = parse(lines[lineNo]).first else { return body }
        if t.due == nil && t.repeat == nil {
            lines[lineNo] = open + "x" + close + rest
            return lines.joined(separator: "\n")
        }
        var clean = rest.replacing(doneMark, with: "")
        while clean.last == " " { clean.removeLast() }
        let c = calendar.dateComponents([.year, .month, .day], from: today)
        lines[lineNo] = open + "x" + close + clean + String(format: " ✅ %04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        if let rule = t.repeat, let due = t.due {
            let next = nextDate(due, rule)
            let marker = "📅 " + next.dateText + (next.hour != nil ? " " + next.timeText : "")
            lines.insert(open + " " + close + clean.replacing(dueMark, with: marker), at: lineNo)
        }
        return lines.joined(separator: "\n")
    }

    /// A hash that stays the same across launches (Swift's `hashValue` does not).
    static func stableHash(_ s: String) -> String {
        var h: UInt32 = 2_166_136_261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return String(h, radix: 36)
    }
}
