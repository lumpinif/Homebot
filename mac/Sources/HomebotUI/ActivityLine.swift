// What one Activity row shows in its single metadata line, and the details behind it (the
// tooltip). Pure, with the clock, calendar and locale injected, so the rules are testable.
import Foundation
import HomebotCore

struct ActivityLine: Equatable {
  /// "1:52 PM · House Helper · 7.5 s": when, the Shortcut's phrase (when the row's title is the
  /// question), the bot (only with more than one bot), and one duration.
  var meta: String
  /// Full date, bot, total and Grok Bot time, step, outcome and reason, one per line.
  var details: String
  /// Answered rows show no status; anything else shows its outcome.
  var showsOutcome: Bool

  init(_ r: ActivityRecord, T: Tr, manyBots: Bool, now: Date = Date(), calendar: Calendar = .current) {
    let at = Date(timeIntervalSince1970: r.at / 1000)
    var parts = [Self.when(at, now: now, locale: T.locale, calendar: calendar)]
    if r.question != nil { parts.append(r.label) }
    let bot = r.botName ?? r.botKey
    if manyBots, let bot { parts.append(bot) }
    parts.append(Self.duration(r, T: T))
    meta = parts.joined(separator: " · ")

    var lines = [at.formatted(Date.FormatStyle(date: .complete, time: .standard).locale(T.locale))]
    if r.question != nil { lines.append(r.label) }
    if let bot { lines.append(bot) }
    let total = Self.seconds(r.durationMs)
    lines.append(r.replyMs.map { T.fmt(T.timings, ["total": total, "reply": Self.seconds($0)]) } ?? T.fmt(T.timingTotal, ["total": total]))
    if let step = r.step, r.run != nil { lines.append(T.fmt(T.activityStep, ["n": "\(step + 1)"])) }
    lines.append(T.outcomeLabel(r.outcome))
    if let reason = r.reason, !reason.isEmpty { lines.append(T.fmt(T.activityReason, ["reason": reason])) }
    details = lines.joined(separator: "\n")
    showsOutcome = r.outcome != "answered"
  }

  /// Today: the time. Yesterday: "Yesterday" in the app's language. Earlier: a short date, with
  /// the year only when it isn't this year's.
  static func when(_ at: Date, now: Date, locale: Locale, calendar: Calendar) -> String {
    var cal = calendar
    cal.locale = locale
    if cal.isDate(at, inSameDayAs: now) {
      return at.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: cal, timeZone: cal.timeZone))
    }
    if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(at, inSameDayAs: y) {
      let f = DateFormatter()
      f.locale = locale
      f.calendar = cal
      f.timeZone = cal.timeZone
      f.dateStyle = .medium
      f.timeStyle = .none
      f.doesRelativeDateFormatting = true
      // Relative formatting compares with the system clock, not `now`: format the clock's own
      // yesterday to get the localized word.
      return f.string(from: cal.date(byAdding: .day, value: -1, to: Date()) ?? at)
    }
    var style = Date.FormatStyle(locale: locale, calendar: cal, timeZone: cal.timeZone).month(.abbreviated).day()
    if cal.component(.year, from: at) != cal.component(.year, from: now) { style = style.year() }
    return at.formatted(style)
  }

  /// The total, plus Grok Bot's own time only when it says something: more than 1 s or 20% off.
  static func duration(_ r: ActivityRecord, T: Tr) -> String {
    let total = seconds(r.durationMs)
    if let reply = r.replyMs, replyDiffers(total: r.durationMs, reply: reply) {
      return T.fmt(T.timings, ["total": total, "reply": seconds(reply)])
    }
    return T.fmt(T.timingTotal, ["total": total])
  }

  static func replyDiffers(total: Int, reply: Int) -> Bool {
    let gap = abs(total - reply)
    return gap > 1000 || Double(gap) > Double(total) * 0.2
  }

  static func seconds(_ ms: Int) -> String { String(format: "%.1f", Double(ms) / 1000) }
}
