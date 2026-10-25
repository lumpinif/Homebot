// One Activity row's single metadata line: the time alone for today, Yesterday or a date
// otherwise, the bot only with more than one bot, Grok Bot's time only when it differs, and no
// status for answered rows. The full details go to the tooltip.
import Foundation
import Testing

import HomebotCore
@testable import HomebotUI

@Suite struct ActivityLineTests {
  let catalog: [Lang: [String: String]]
  init() throws { catalog = try L10n.catalog(catalogURL) }
  func tr(_ l: Lang) -> Tr { Tr(lang: l, table: catalog[l]!, fallback: catalog[.en]!) }

  var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return c
  }
  /// 2026-10-24 15:00 in Shanghai.
  var now: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 15))! }
  func ms(_ d: Date) -> Double { d.timeIntervalSince1970 * 1000 }

  func record(at: Date, total: Int = 7500, reply: Int? = 7480, outcome: String = "answered", bot: String = "homebot") -> ActivityRecord {
    ActivityRecord(at: ms(at), durationMs: total, replyMs: reply, tokenId: "t", label: "居家助手", mode: "ask",
                   botKey: bot, botName: bot, question: "给我说个笑话", spoken: "…", outcome: outcome, reason: outcome == "answered" ? nil : "O5")
  }

  @Test func whenIsTimeTodayYesterdayOrADate() {
    let en = Locale(identifier: "en_US"), zh = Locale(identifier: "zh-Hans")
    let today = cal.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 13, minute: 52))!
    let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
    let earlier = cal.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 9))!
    let lastYear = cal.date(from: DateComponents(year: 2025, month: 12, day: 30, hour: 9))!
    #expect(ActivityLine.when(today, now: now, locale: en, calendar: cal).contains("1:52"))
    #expect(!ActivityLine.when(today, now: now, locale: en, calendar: cal).contains("Oct"))
    #expect(ActivityLine.when(yesterday, now: now, locale: en, calendar: cal) == "Yesterday")
    #expect(ActivityLine.when(yesterday, now: now, locale: zh, calendar: cal) == "昨天")
    #expect(ActivityLine.when(earlier, now: now, locale: en, calendar: cal) == "Oct 3")
    #expect(ActivityLine.when(lastYear, now: now, locale: en, calendar: cal).contains("2025"))
  }

  @Test func oneLineWithThePhraseAndOneDuration() {
    let today = cal.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 13, minute: 52))!
    let line = ActivityLine(record(at: today), T: tr(.en), manyBots: false, now: now, calendar: cal)
    #expect(!line.meta.contains("homebot"), "one bot: no bot name")
    #expect(!line.meta.contains("Grok Bot"), "Grok Bot's time equals the total")
    #expect(line.meta.hasSuffix("· 居家助手 · 7.5 s"), "\(line.meta)")
    #expect(!line.meta.contains("\n"))
    #expect(!line.showsOutcome)
    #expect(line.details.contains("homebot") && line.details.contains("Grok Bot 7.5 s"))

    let two = ActivityLine(record(at: today), T: tr(.zhHans), manyBots: true, now: now, calendar: cal)
    #expect(two.meta.hasSuffix("· 居家助手 · homebot · 7.5 秒"), "\(two.meta)")
  }

  @Test func grokBotTimeOnlyWhenItDiffers() {
    #expect(!ActivityLine.replyDiffers(total: 7500, reply: 7480))
    #expect(!ActivityLine.replyDiffers(total: 7500, reply: 6600))  // 0.9 s and 12%
    #expect(ActivityLine.replyDiffers(total: 7500, reply: 6400))   // 1.1 s
    #expect(ActivityLine.replyDiffers(total: 2000, reply: 1500))   // 25%
    let line = ActivityLine(record(at: now, total: 9000, reply: 3000), T: tr(.en), manyBots: false, now: now, calendar: cal)
    #expect(line.meta.hasSuffix("9.0 s · Grok Bot 3.0 s"), "\(line.meta)")
  }

  @Test func otherOutcomesShowTheirStatusAndReason() {
    let line = ActivityLine(record(at: now, outcome: "refused"), T: tr(.en), manyBots: false, now: now, calendar: cal)
    #expect(line.showsOutcome)
    #expect(line.details.contains("O5"))
  }
}
