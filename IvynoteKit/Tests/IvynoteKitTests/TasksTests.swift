import Foundation
import Testing
@testable import IvynoteKit

struct TasksTests {
    let sealed = "```ivy-encrypted\nThis note is encrypted.\nv: 1\nkdf: scrypt N=32768 r=8 p=1\nsalt: AA==\nnonce: AA==\ndata: AA==\n```\n"
    var shanghai: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    @Test func detectsProtectedNotes() {
        #expect(NoteLock.isEncrypted(sealed))
        #expect(!NoteLock.isEncrypted("x\n" + sealed))
        #expect(!NoteLock.isEncrypted("plain"))
    }

    @Test func parsesTasks() {
        let ts = Tasks.parse("- [ ] 交房租 📅 2026-11-15 09:00 🔁 every month\n```\n- [ ] code 📅 2026-11-01\n```\n* [x] done ✅ 2026-11-01 📅 2026-10-31\n- [ ] bad 📅 2026-02-30\n- [ ] plain")
        #expect(ts.count == 4)
        #expect(ts[0].text == "交房租")
        #expect(ts[0].due == Tasks.Due(year: 2026, month: 11, day: 15, hour: 9, minute: 0))
        #expect(ts[0].repeat == Tasks.Repeat(every: 1, unit: "month", text: "every month"))
        #expect(ts[1].done && ts[1].line == 4)
        #expect(ts[2].due == nil)
        #expect(Tasks.parseRepeat("every 2 weeks") == Tasks.Repeat(every: 2, unit: "week", text: "every 2 weeks"))
        #expect(Tasks.parseRepeat("sometimes") == nil)
    }

    @Test func listsRemindersAndAgenda() {
        let cal = shanghai
        let notes = [
            Note(id: "a", title: "生活", body: "- [ ] 早 📅 2026-11-09 08:00\n- [ ] 全天 📅 2026-11-09\n- [ ] 过期 📅 2026-11-01\n- [x] 完成 📅 2026-11-09 ✅ 2026-11-09", createdAt: 1, updatedAt: 1),
            Note(id: "b", title: "回收", body: "- [ ] x 📅 2026-11-09 08:00", trashedAt: 5, createdAt: 1, updatedAt: 1),
            Note(id: "c", title: "秘密", body: sealed, createdAt: 1, updatedAt: 1),
        ]
        let from = cal.date(from: DateComponents(year: 2026, month: 11, day: 9))!
        let to = cal.date(from: DateComponents(year: 2026, month: 11, day: 10))!
        #expect(Tasks.reminders(notes, from: from, to: to, allDay: nil, calendar: cal).map(\.text) == ["早"])
        let all = Tasks.reminders(notes, from: from, to: to, allDay: (9, 0), calendar: cal)
        #expect(all.map(\.text) == ["早", "全天"])
        let agenda = Tasks.agenda(notes, today: from, calendar: cal)
        #expect(agenda.map(\.task.text) == ["过期", "早", "全天"])
        #expect(agenda.map(\.days) == [-8, 0, 0])
    }

    @Test func togglesLikeTheEditor() {
        let cal = shanghai
        let today = cal.date(from: DateComponents(year: 2026, month: 11, day: 15))!
        #expect(Tasks.toggle("- [ ] 交房租 📅 2026-11-15 09:00 🔁 every month", line: 0, today: today, calendar: cal)
            == "- [ ] 交房租 📅 2026-12-15 09:00 🔁 every month\n- [x] 交房租 📅 2026-11-15 09:00 🔁 every month ✅ 2026-11-15")
        #expect(Tasks.toggle("- [x] a 📅 2026-11-15 ✅ 2026-11-15", line: 0, today: today, calendar: cal) == "- [ ] a 📅 2026-11-15")
        #expect(Tasks.toggle("- [ ] plain", line: 0, today: today, calendar: cal) == "- [x] plain")
        #expect(Tasks.toggle("text", line: 0, today: today, calendar: cal) == "text")
    }
}
