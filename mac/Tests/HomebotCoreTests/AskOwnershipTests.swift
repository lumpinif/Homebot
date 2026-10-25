// Ported from test/ask-ownership.test.ts (AskService over exact page sequences, without the fake
// API) and the follow-up wait tests of test/conversation.test.ts.
import Foundation
import Testing

@testable import HomebotCore

private let PRIV = "a separate task's private output"

struct Scripted {
  let bdk: ScriptedBdk
  let svc: AskService
  let logs: LogSink

  func ask(_ text: String = "hi", waitIdleMs: Int = 0) async -> AskResult {
    await svc.ask(AskRequest(botKey: "chai", text: text, lang: .zhCN, turn: waitIdleMs > 0 ? 2 : nil, waitIdleMs: waitIdleMs))
  }

  var log: LogEvent? { logs.first("ask") }
}

func scripted(before: [ScriptedPage] = [], budget: Int = 1000, traceIdle: AskService.TraceIdle = .init(maxMs: 0, everyMs: 1000), _ script: @escaping @Sendable (ScriptedBdk.Sent) -> [ScriptedPage]) async throws -> Scripted {
  let dir = try tmpDir()
  let config = try await ConfigStore(file: dir.appendingPathComponent("config.json")).load()
  var p = SettingsPatch()
  p.pollMs = 5
  p.answerBudgetMs = budget
  try await config.putSettings(p)
  try await config.putBot(Bot(key: "chai", name: "拆解师", sessionId: "1", strictEcho: true))
  let state = try await StateStore(file: dir.appendingPathComponent("state.json")).load()
  try await state.setCursor("chai", cursor: "100", maxSeq: "100", sessionId: "1")
  let bdk = ScriptedBdk(before: before, script)
  let logs = LogSink()
  let svc = AskService(config: config, state: state, bdk: { BdkSession(client: bdk) }, log: logs.fn, traceIdle: traceIdle)
  return Scripted(bdk: bdk, svc: svc, logs: logs)
}

private func tag(_ s: ScriptedBdk.Sent) -> String { Envelope.echoTag(s.messageId) }

@Suite("AskService ownership over exact pages")
struct AskOwnershipTests {
  typealias S = Script

  @Test("B1: a replacement of the accepted reply in a later poll is never fetched or spoken")
  func laterReplacement() async throws {
    let t = try await scripted { s in [S.page([S.ours(101, s), S.reply(102, "\(tag(s)) OWNED")]), S.end(), S.page([S.reply(102, PRIV)]), S.end()] }
    let r = await t.ask()
    #expect(r.outcome == "answered")
    #expect(r.text == "OWNED")
    #expect(t.bdk.remaining == 2, "the answer is returned at once; nothing after it is read")
  }

  @Test("B1: a replacement seen before answering is checked again and refused (O5)")
  func earlyReplacement() async throws {
    let t = try await scripted { s in [S.page([S.ours(101, s), S.reply(102, "\(tag(s)) OWNED"), S.reply(102, PRIV)]), S.end()] }
    let r = await t.ask()
    #expect(r.reason == "O5")
    #expect(!r.text.contains(PRIV))
  }

  @Test("B1: late O2/O3 evidence in the same observation refuses")
  func lateEvidence() async throws {
    let a = try await scripted { s in
      [S.page([Entry(seq: "101", kind: "status"), S.ours(102, s), S.reply(103, "\(tag(s)) \(PRIV)"), Entry(seq: "101", kind: "status", role: "user")]), S.end()]
    }
    #expect(await a.ask().reason == "O2")
    let b = try await scripted { s in
      [S.page([Entry(seq: "101", kind: "status"), S.ours(102, s), S.reply(103, "\(tag(s)) \(PRIV)"), Entry(seq: "101", kind: "send-message")]), S.end()]
    }
    #expect(await b.ask().reason == "O3")
  }

  @Test("B2: untagged output after the proved reply is never spoken, in the same poll or later", arguments: [false, true])
  func untaggedAfter(split: Bool) async throws {
    let t = try await scripted { s in
      [S.page([S.ours(101, s), S.reply(102, "\(tag(s)) OWNED")] + (split ? [] : [S.reply(103, PRIV)])), S.end()] + (split ? [S.page([S.reply(103, PRIV)]), S.end()] : [])
    }
    let r = await t.ask()
    #expect(r.text == "OWNED")
    #expect(!r.text.contains(PRIV) && !t.logs.json.contains(PRIV))
  }

  // Interim progress deliveries (DESIGN §4.2, DECISIONS item 26): the tagged delivery is spoken,
  // untagged ones before it are skipped and counted; no tag by the turn's end or the deadline is O5.
  static let interimText = "正在查你最新的 Gmail。"

  @Test("interim: an untagged progress message, then the tagged reply in a later poll: the tagged text is spoken")
  func interimThenTagged() async throws {
    let t = try await scripted { s in
      [S.page([S.ours(101, s), S.reply(102, Self.interimText)], Script.busy), S.end(Script.busy), S.end(Script.busy),
       S.page([S.reply(103, "\(tag(s)) 你最新一封邮件来自 Vercel。")], Script.busy), S.end(Script.busy)]
    }
    let r = await t.ask("我最近一封Gmail邮件是什么")
    #expect(r.outcome == "answered")
    #expect(r.text == "你最新一封邮件来自 Vercel。")
    #expect(r.delivery == 2 && r.interim == 1)
    #expect(t.log?["delivery"] == 2 && t.log?["interim"] == 1)
    #expect(!t.logs.json.contains(Self.interimText), "counts only, never text")
  }

  @Test("interim: a tagged reply, then untagged output: only the tagged text is spoken")
  func taggedThenUntagged() async throws {
    let t = try await scripted { s in [S.page([S.ours(101, s), S.reply(102, "\(tag(s)) OWNED"), S.reply(103, PRIV)], Script.busy), S.end(Script.busy)] }
    let r = await t.ask()
    #expect(r.text == "OWNED")
    #expect(r.delivery == 1 && r.interim == 0)
    #expect(!t.logs.json.contains(PRIV))
  }

  @Test("interim: only untagged output while the turn stays busy: refused (O5) at the deadline, never spoken")
  func untaggedUntilDeadline() async throws {
    let t = try await scripted(budget: 300) { s in [S.page([S.ours(101, s), S.reply(102, PRIV)], Script.busy), S.end(Script.busy)] }
    let t0 = Date()
    let r = await t.ask()
    #expect(Date().timeIntervalSince(t0) > 0.25, "waits for a tagged delivery until the deadline")
    #expect(r.outcome == "refused" && r.reason == "O5")
    #expect(r.text == zh.refused)
    #expect(r.interim == 1 && r.delivery == nil)
    #expect(t.log?["end"] == "deadline")
    #expect(!t.logs.json.contains(PRIV))
  }

  @Test("interim: only untagged output and the turn goes idle: refused (O5) after two idle polls, before the deadline")
  func untaggedThenIdle() async throws {
    let t = try await scripted(budget: 5000) { s in [S.page([S.ours(101, s), S.reply(102, PRIV)], Script.busy), S.end(Script.busy), S.end(.idleNow)] }
    let t0 = Date()
    let r = await t.ask()
    #expect(Date().timeIntervalSince(t0) < 2)
    #expect(r.outcome == "refused" && r.reason == "O5")
    #expect(t.log?["end"] == "idle")
    #expect(!r.text.contains(PRIV))
  }

  @Test("interim: one idle poll between deliveries is not the turn's end; the tagged reply is still spoken")
  func idleFlicker() async throws {
    let t = try await scripted(budget: 5000) { s in
      [S.page([S.ours(101, s), S.reply(102, Self.interimText)], Script.busy), S.end(.idleNow), S.page([S.reply(103, "\(tag(s)) OWNED")], Script.busy), S.end(Script.busy)]
    }
    let r = await t.ask()
    #expect(r.outcome == "answered" && r.text == "OWNED")
    #expect(r.interim == 1)
  }

  @Test("interim: idle polls before the interim message don't count toward the turn's end")
  func idleBeforeInterim() async throws {
    let t = try await scripted(budget: 5000) { s in
      [S.end(.idleNow), S.end(.idleNow), S.page([S.ours(101, s), S.reply(102, Self.interimText)], .idleNow), S.end(.idleNow),
       S.page([S.reply(103, "\(tag(s)) OWNED")], Script.busy), S.end(Script.busy)]
    }
    let r = await t.ask()
    #expect(r.outcome == "answered" && r.text == "OWNED")
  }

  @Test("interim: foreign input after an interim message refuses (O2), also when the tagged reply follows")
  func interimForeignInput() async throws {
    let t = try await scripted { s in
      [S.page([S.ours(101, s), S.reply(102, Self.interimText)], Script.busy), S.end(Script.busy),
       S.page([Entry(seq: "103", kind: "message", role: "user", text: "desktop"), S.reply(104, "\(tag(s)) \(PRIV)")], Script.busy), S.end(Script.busy)]
    }
    let r = await t.ask()
    #expect(r.reason == "O2")
    #expect(!r.text.contains(PRIV))
  }

  @Test("interim: a delivery tagged for another request refuses (O5), even with ours later")
  func interimForeignTag() async throws {
    let t = try await scripted { s in
      [S.page([S.ours(101, s), S.reply(102, "[hb:ffffffffffff] \(PRIV)")], Script.busy), S.end(Script.busy),
       S.page([S.reply(103, "\(tag(s)) OWNED")], Script.busy), S.end(Script.busy)]
    }
    let r = await t.ask()
    #expect(r.reason == "O5")
    #expect(!r.text.contains(PRIV) && !r.text.contains("OWNED"))
  }

  @Test("interim, follow-up mode: after the idle wait, an interim message is skipped and the tagged reply spoken")
  func followupInterim() async throws {
    let t = try await scripted(before: [S.page([], Script.busy), S.page([], .idleNow)], budget: 2000) { s in
      [S.page([S.ours(110, s), S.reply(111, Self.interimText)], Script.busy), S.end(Script.busy), S.page([S.reply(112, "\(tag(s)) OWNED")], Script.busy), S.end(Script.busy)]
    }
    let r = await t.ask("那后天呢", waitIdleMs: 1000)
    #expect(r.outcome == "answered" && r.text == "OWNED")
    #expect(r.delivery == 2)
  }

  @Test("interim, follow-up mode: only untagged output is refused (O5); foreign input is refused (O2)")
  func followupInterimRefused() async throws {
    let a = try await scripted(before: [S.page([], .idleNow)], budget: 2000) { s in [S.page([S.ours(110, s), S.reply(111, PRIV)], Script.busy), S.end(.idleNow)] }
    let ra = await a.ask("那后天呢", waitIdleMs: 1000)
    #expect(ra.reason == "O5" && !ra.text.contains(PRIV))
    let b = try await scripted(before: [S.page([], .idleNow)], budget: 2000) { s in
      [S.page([S.ours(110, s), S.reply(111, Self.interimText), Entry(seq: "112", kind: "message", role: "user", text: "desktop")], Script.busy), S.end(Script.busy)]
    }
    #expect(await b.ask("那后天呢", waitIdleMs: 1000).reason == "O2")
  }

  @Test("S3: missing, malformed or stuck-busy turn flags change neither ownership nor timing")
  func turnFlags() async throws {
    let malformed = Turn(idle: .string("yes"), inFlight: .string("no"))
    let cases: [(Turn?, Character)] = [(nil, "?"), (malformed, "?"), (Turn(), "?"), (Script.busy, "B")]
    for (turn, code) in cases {
      let t = try await scripted { s in [S.end(turn), S.page([S.ours(101, s)], turn), S.end(turn), S.page([S.reply(102, "\(tag(s)) OWNED"), S.reply(103, PRIV)], turn), S.end(turn)] }
      let t0 = Date()
      let r = await t.ask()
      #expect(r.text == "OWNED")
      #expect(Date().timeIntervalSince(t0) < 0.3, "answered as soon as the reply was proved")
      guard case .string(let turns)? = t.log?["turns"] else {
        Issue.record("no trace")
        continue
      }
      #expect(!turns.isEmpty && turns.allSatisfy { $0 == code }, "trace for \(String(describing: turn))")
    }
  }

  @Test("N1: the trace marks only a fully valid idle state as idle")
  func turnCodes() {
    #expect(turnCode(.idleNow) == "I")
    #expect(turnCode(Script.busy) == "B")
    #expect(turnCode(Turn(idle: .bool(false), inFlight: .bool(false), queued: .number(0))) == "B")
    #expect(turnCode(Turn(idle: .bool(true), inFlight: .bool(false), queued: .number(3))) == "B")
    #expect(turnCode(nil) == "?")
    #expect(turnCode(Turn()) == "?")
    #expect(turnCode(Turn(idle: .bool(true))) == "?")
    #expect(turnCode(Turn(idle: .bool(true), inFlight: .string("false"), queued: .number(0))) == "?")
  }

  @Test("R1: foreign input seen before a failed page still refuses (O2)")
  func r1O2() async throws {
    let t = try await scripted { s in
      [S.page([Entry(seq: "101", kind: "message", role: "user", text: "desktop message")]), .failing,
       S.page([Entry(seq: "101", kind: "message", text: "desktop message"), S.ours(102, s), S.reply(103, "\(tag(s)) \(PRIV)")]), S.end()]
    }
    let r = await t.ask()
    #expect(r.outcome == "refused")
    #expect(r.reason == "O2")
    #expect(!r.text.contains(PRIV))
    #expect(t.log?["poll_errors"] == 1)
  }

  @Test("R1: foreign output seen before a failed page still refuses (O3)")
  func r1O3() async throws {
    let t = try await scripted { s in
      [S.page([Entry(seq: "101", kind: "send-message")]), .failing, S.page([Entry(seq: "101", kind: "status"), S.ours(102, s), S.reply(103, "\(tag(s)) \(PRIV)")]), S.end()]
    }
    let r = await t.ask()
    #expect(r.reason == "O3")
    #expect(!r.text.contains(PRIV))
  }

  @Test("R1: another request's tag seen before a failed page still refuses (O5)")
  func r1O5() async throws {
    let t = try await scripted { s in [S.page([S.ours(101, s), S.reply(102, "[hb:ffffffffffff] \(PRIV)")]), .failing, S.page([S.ours(101, s), S.reply(102, "\(tag(s)) OWNED")]), S.end()] }
    let r = await t.ask()
    #expect(r.reason == "O5")
    #expect(!r.text.contains(PRIV) && !r.text.contains("OWNED"))
  }

  @Test("B1: a proved candidate from an incomplete poll waits for a complete one")
  func incompletePoll() async throws {
    let t = try await scripted { s in
      [S.page([S.ours(101, s), S.reply(102, "\(tag(s)) OWNED")]), .failing,
       S.page([S.ours(101, s), S.reply(102, "\(tag(s)) OWNED"), Entry(seq: "103", kind: "message", role: "user", text: "desktop")]), S.end()]
    }
    let r = await t.ask()
    #expect(r.outcome == "refused")
    #expect(!r.text.contains("OWNED"))
  }

  @Test("R1: a failed page alone does not stop a proved answer")
  func failedPageAlone() async throws {
    let t = try await scripted { s in [S.page([S.ours(101, s)]), .failing, S.page([S.ours(101, s), S.reply(102, "\(tag(s)) OWNED")]), S.end()] }
    let r = await t.ask()
    #expect(r.outcome == "answered")
    #expect(r.text == "OWNED")
    #expect(t.log?["poll_errors"] == 1)
  }

  @Test("R2: an unknown error never reaches the ask log by name")
  func unknownError() async throws {
    struct SyntheticPrivateErrorName: Error {}
    let t = try await scripted { _ in [] }
    t.bdk.entriesOverride = { throw SyntheticPrivateErrorName() }
    let r = await t.ask()
    #expect(r.outcome == "error")
    #expect(!t.logs.json.contains("Synthetic"))
    #expect(t.log?["error"] == "other")
  }

  // DESIGN §18.3: diagnostics of how long a turn stays busy after its answer was returned.
  func tail(_ t: Scripted) async -> LogEvent? {
    _ = await eventually { t.logs.first("turn-tail") != nil }
    return t.logs.first("turn-tail")
  }

  @Test("turn tail: the answer returns at once; the tail is traced until idle")
  func tailIdle() async throws {
    let t = try await scripted(traceIdle: .init(maxMs: 500, everyMs: 5)) { s in
      [S.page([S.ours(101, s), S.reply(102, "\(tag(s)) OWNED")], Script.busy), S.end(Script.busy), S.page([S.reply(103, "a second part")], Script.busy), S.end(Script.busy),
       S.page([Entry(seq: "104", kind: "message", role: "user", text: "desktop")], Script.busy), S.end(.idleNow)]
    }
    let r = await t.ask()
    #expect(r.outcome == "answered")
    let e = try must(await tail(t))
    #expect(e["outcome"] == "idle")
    #expect(e["requestId"] == .string(r.requestId ?? ""))
    #expect(e["idle_after_ms"] != nil)
    #expect(e["polls"] == 2, "one poll per sync until the first idle sync")
    #expect(e["deliveries"] == 1 && e["user_entries"] == 1, "other activity during the tail is counted, never spoken")
  }

  @Test("turn tail: a turn that never goes idle is logged as timeout")
  func tailTimeout() async throws {
    let t = try await scripted(traceIdle: .init(maxMs: 100, everyMs: 5)) { s in [S.page([S.ours(101, s), S.reply(102, "\(tag(s)) OWNED")], Script.busy), S.end(Script.busy)] }
    _ = await t.ask()
    let e = try must(await tail(t))
    #expect(e["outcome"] == "timeout")
    #expect(e["idle_after_ms"] == nil)
  }

  @Test("turn tail: a new request for the session stops the trace")
  func tailSuperseded() async throws {
    let t = try await scripted(traceIdle: .init(maxMs: 2000, everyMs: 5)) { s in [S.page([S.ours(101, s), S.reply(102, "\(tag(s)) OWNED")], Script.busy), S.end(Script.busy)] }
    _ = await t.ask()
    let svc = t.svc
    Task { _ = await svc.ask(AskRequest(botKey: "chai", text: "again")) }
    let e = try must(await tail(t))
    #expect(e["outcome"] == "superseded")
    await svc.stop()
  }

  // Follow-up wait (DESIGN §18.3), from test/conversation.test.ts.
  static func ownedAt110(_ s: ScriptedBdk.Sent) -> [ScriptedPage] { [Script.page([Script.ours(110, s), Script.reply(111, "\(tag(s)) OWNED")]), Script.page([])] }

  @Test("follow-up wait: the previous turn's tail goes below the new baseline and is never spoken")
  func followupTail() async throws {
    let t = try await scripted(before: [S.page([], Script.busy), S.page([S.reply(101, "the rest of the previous answer")], Script.busy), S.page([], Script.busy), S.page([], .idleNow)], budget: 2000, Self.ownedAt110)
    let r = await t.ask("那后天呢", waitIdleMs: 1000)
    #expect(r.outcome == "answered")
    #expect(r.text == "OWNED")
    #expect(t.bdk.sent == 1)
  }

  @Test("follow-up wait: a user entry during the wait answers busy and sends nothing")
  func followupUser() async throws {
    let t = try await scripted(before: [S.page([], Script.busy), S.page([Entry(seq: "101", kind: "message", role: "user", text: "desktop")], Script.busy), S.page([], Script.busy)], budget: 2000, Self.ownedAt110)
    let r = await t.ask("那后天呢", waitIdleMs: 1000)
    #expect(r.outcome == "busy")
    #expect(t.bdk.sent == 0)
    #expect(t.log?["wait"] == "user")
  }

  @Test("follow-up wait: a user entry in the first sync counts too (conversation review B1)")
  func followupFirstSync() async throws {
    let t = try await scripted(before: [S.page([Entry(seq: "101", kind: "message", role: "user", text: "desktop")], Script.busy), S.page([], Script.busy), S.page([], .idleNow)], budget: 2000, Self.ownedAt110)
    #expect(await t.ask("那后天呢", waitIdleMs: 1000).outcome == "busy")
    #expect(t.bdk.sent == 0)
  }

  @Test("follow-up wait: no wait (0) or a turn that stays busy answers busy and sends nothing")
  func followupNoWait() async throws {
    let a = try await scripted(before: [S.page([], Script.busy), S.page([], .idleNow)], budget: 2000, Self.ownedAt110)
    #expect(await a.ask("那后天呢", waitIdleMs: 0).outcome == "busy", "0 keeps today's immediate busy")
    #expect(a.bdk.sent == 0)
    let b = try await scripted(before: Array(repeating: S.page([], Script.busy), count: 200), budget: 2000, Self.ownedAt110)
    #expect(await b.ask("那后天呢", waitIdleMs: 30).outcome == "busy")
    #expect(b.bdk.sent == 0)
    // About one poll per 5 ms of the 30 ms allowance; a poll without a sleep near the end of the
    // allowance used to read every scripted page, reach an idle one and send (S5).
    #expect(200 - b.bdk.beforeRemaining <= 15, "the wait polls at the poll interval, never in a tight loop")
  }
}
