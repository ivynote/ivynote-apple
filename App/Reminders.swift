import IvynoteKit
import UserNotifications

/// Reminders for tasks with a 📅 date (guide 9.4, 11.8): whenever a
/// library's notes change, its next reminders are handed to the system as
/// local notifications, so they arrive while the app is closed. Protected
/// notes take no part: their tasks are encrypted.
@MainActor
enum Reminders {
    /// The system keeps at most 64 pending notifications per app.
    private static let limit = 48
    private static let horizon: TimeInterval = 14 * 24 * 3600
    /// A date without a time reminds at this hour (as on the web).
    static let allDay = (hour: 9, minute: 0)
    private static var asked = false

    private static func idPrefix(_ library: String) -> String { "ivy.reminder.\(library)." }

    static func schedule(_ notes: [Note], library: String) async {
        let center = UNUserNotificationCenter.current()
        let now = Date()
        let next = Tasks.reminders(notes, from: now, to: now.addingTimeInterval(horizon), allDay: allDay).prefix(limit)
        let prefix = idPrefix(library)
        let wanted = Set(next.map { prefix + $0.key })

        // Ask once, the first time there is something to remind of.
        if !next.isEmpty && !asked {
            asked = true
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
        }

        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(prefix) && !wanted.contains($0) }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        let have = Set(pending.map(\.identifier))

        for r in next where !have.contains(prefix + r.key) {
            let content = UNMutableNotificationContent()
            content.title = r.text.isEmpty ? (r.noteTitle.isEmpty ? L.untitled : r.noteTitle) : r.text
            if !r.noteTitle.isEmpty { content.body = L.reminderFrom(r.noteTitle) }
            content.sound = .default
            content.userInfo = ["library": library, "note": r.noteId, "line": r.line]
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: r.at)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: prefix + r.key, content: content, trigger: trigger))
        }
    }

    /// Stops the reminders of a library (signed out, removed).
    static func clear(library: String) async {
        let center = UNUserNotificationCenter.current()
        let prefix = idPrefix(library)
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
