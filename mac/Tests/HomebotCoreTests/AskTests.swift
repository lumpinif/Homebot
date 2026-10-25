// Ported from test/ask.test.ts (AskService against the fake Grok Bot API) and the follow-up wait
// tests of test/conversation.test.ts.
import Foundation
import Testing

@testable import HomebotCore

let SID = "14752726"
let zh = Messages.of(.zhCN)
let PRIVATE = "这是给桌面的私密回复"

struct AskHarness {
  let fake: FakeGrokBot
  let svc: AskService
  let state: StateStore
  let config: ConfigStore
  let logs: LogSink

  func ask(_ text: String, lang: ReplyLang = .zhCN, bot: String = "chai", signal: CancelSignal? = nil) async -> AskResult {
    await svc.ask(AskRequest(botKey: bot, sessionId: nil, text: text, lang: lang, signal: signal))
  }

  var askLog: LogEvent? { logs.first("ask") }
}

func askHarness(settings: SettingsPatch = SettingsPatch(), strictEcho: Bool = true, history: Int = 5, key: String = FakeGrokBot.key, writeCursor: (@Sendable (String, String, String, String) async throws -> Void)? = nil) async throws -> AskHarness {
  let fake = FakeGrokBot()
  for i in 0..<history { fake.add(SID, kind: i % 2 == 1 ? "send-message" : "message", role: i % 2 == 1 ? nil : "user", text: "old \(i)") }
  let dir = try tmpDir()
  let config = try await ConfigStore(file: dir.appendingPathComponent("config.json")).load()
  var p = SettingsPatch()
  p.answerBudgetMs = 1500
  p.pollMs = 10
  try await config.putSettings(p)
  try await config.putSettings(settings)
  try await config.putBot(Bot(key: "chai", name: "拆解师", sessionId: SID, strictEcho: strictEcho))
  let state = try await StateStore(file: dir.appendingPathComponent("state.json")).load()
  let c = try await Bots.coldSync(fake.client(), sessionId: SID)
  try await state.setCursor("chai", cursor: c.cursor, maxSeq: c.maxSeq, sessionId: SID)
  let logs = LogSink()
  let client = fake.client(key: key)
  let svc = AskService(config: config, state: state, bdk: { BdkSession(client: client, key: key) }, log: logs.fn, writeCursor: writeCursor)
  return AskHarness(fake: fake, svc: svc, state: state, config: config, logs: logs)
}

@Suite("AskService")
struct AskTests {
  @Test("happy path: owned, echoed reply is spoken without the tag")
  func happy() async throws {
    let h = try await askHarness()
    h.fake.autoReply(SID, text: "现在**三点**。")
    let r = await h.ask("几点了")
    #expect(r.outcome == "answered")
    #expect(r.text == "现在三点。")
    #expect(h.fake.posts.count == 1)
    #expect(h.fake.posts[0].text.firstMatch(of: /^\[Homebot voice · hb:[0-9a-f]{12} · zh-CN\]\n几点了\n/) != nil)
    #expect(h.fake.posts[0].messageId == r.requestId)
    #expect(h.fake.requests.allSatisfy { $0.client == "agent-serve" })
    #expect(!h.logs.json.contains("几点了"), "question text is never logged")
  }

  @Test("baseline walks a >200-entry backlog and never speaks old replies")
  func backlog() async throws {
    let h = try await askHarness(history: 3)
    for i in 0..<450 { h.fake.add(SID, kind: "send-message", text: "backlog \(i)") }
    h.fake.autoReply(SID, text: "新回答。")
    let r = await h.ask("你好")
    #expect(r.text == "新回答。")
    await h.svc.flush()
    let cur = try must(await h.state.cursor("chai"))
    #expect(try Seq.parse(cur.cursor) > Seq.parse("1450"))
  }

  @Test("B1: desktop message between the idle check and our send -> refused, private text never returned")
  func desktopBeforeSend() async throws {
    let h = try await askHarness()
    let fake = h.fake
    let injected = Flag()
    fake.intercept = { method, what, _, _ in
      if what == "messages" && method == "POST" && !injected.isSet {
        injected.set()
        fake.add(SID, kind: "message", role: "user", text: "桌面上的问题")
        Task {
          await sleepMs(5)
          fake.add(SID, kind: "send-message", text: PRIVATE)
        }
      }
      return nil
    }
    fake.autoReply(SID, ms: 40, text: "语音回答")
    let r = await h.ask("几点了")
    #expect(r.outcome == "refused")
    #expect(r.reason == "O2")
    #expect(r.text == zh.refused)
    #expect(!r.text.contains(PRIVATE) && !h.logs.json.contains(PRIVATE))
  }

  @Test("B1: desktop message after ours, before the reply -> refused")
  func desktopAfterOurs() async throws {
    let h = try await askHarness()
    let fake = h.fake
    fake.setOnMessage { _, msg in
      let id = msg.firstMatch(of: /hb:([0-9a-f]{12})/).map { String($0.1) } ?? ""
      fake.add(SID, kind: "message", role: "user", text: "桌面插话")
      Task {
        await sleepMs(10)
        fake.add(SID, kind: "send-message", text: "[hb:\(id)] \(PRIVATE)")
      }
    }
    let r = await h.ask("几点了")
    #expect(r.outcome == "refused")
    #expect(!r.text.contains(PRIVATE))
  }

  @Test("B4: foreign output re-updated without text before we poll -> refused")
  func foreignTextless() async throws {
    let h = try await askHarness()
    let fake = h.fake
    fake.intercept = { method, what, _, _ in
      if what == "messages" && method == "POST" && fake.posts.isEmpty {
        let e = fake.add(SID, kind: "send-message", text: PRIVATE)
        fake.touch(SID, seq: e.seq, text: .some(nil))
      }
      return nil
    }
    fake.autoReply(SID, text: PRIVATE)
    let r = await h.ask("几点了")
    #expect(r.outcome == "refused")
    #expect(r.reason == "O3")
    #expect(!r.text.contains(PRIVATE))
  }

  @Test("B1: reply without the echo tag is refused in strict mode")
  func strictUntagged() async throws {
    let h = try await askHarness()
    h.fake.autoReply(SID, text: PRIVATE, echo: false)
    let r = await h.ask("几点了")
    #expect(r.reason == "O5")
    #expect(!r.text.contains(PRIVATE))
  }

  @Test("non-strict bot accepts an untagged reply")
  func nonStrict() async throws {
    let h = try await askHarness(strictEcho: false)
    h.fake.autoReply(SID, text: "好的。", echo: false)
    let r = await h.ask("你好")
    #expect(r.text == "好的。")
    #expect(!h.fake.posts[0].text.contains("[hb:"), "no echo instruction when strict is off")
  }

  @Test("busy bot: nothing is sent")
  func busy() async throws {
    let h = try await askHarness()
    h.fake.setIdle(SID, false)
    let r = await h.ask("你好")
    #expect(r.outcome == "busy")
    #expect(r.text == zh.busy("拆解师"))
    #expect(h.fake.posts.isEmpty)
  }

  @Test("S1: deadline before send -> nothing sent, 'not sent' message")
  func deadlineBeforeSend() async throws {
    var p = SettingsPatch()
    p.answerBudgetMs = 100
    let h = try await askHarness(settings: p)
    h.fake.intercept = { _, what, _, _ in
      if what == "entries" { await sleepMs(300) }
      return nil
    }
    let r = await h.ask("你好")
    #expect(r.outcome == "not-sent:deadline")
    #expect(r.text == zh.notSent)
    await sleepMs(300)
    #expect(h.fake.posts.isEmpty)
  }

  @Test("S1: client disconnect before send aborts without sending")
  func disconnectBeforeSend() async throws {
    let h = try await askHarness()
    let signal = CancelSignal()
    h.fake.intercept = { _, what, _, _ in
      if what == "entries" {
        signal.cancel()
        await sleepMs(50)
      }
      return nil
    }
    let r = await h.ask("你好", signal: signal)
    #expect(r.outcome == "not-sent:disconnect")
    await sleepMs(100)
    #expect(h.fake.posts.isEmpty)
  }

  @Test("S1: uncertain send is retried with the same messageId and the answer still arrives")
  func uncertainSend() async throws {
    let h = try await askHarness()
    h.fake.intercept = { method, what, _, attempt in what == "messages" && method == "POST" && attempt == 1 ? .acceptThenDestroy : nil }
    h.fake.autoReply(SID, text: "到了。")
    let r = await h.ask("你好")
    #expect(r.outcome == "answered")
    #expect(h.fake.posts.count == 1, "server stored the message once")
    #expect(h.fake.requests.filter { $0.method == "POST" }.count == 2, "client retried")
  }

  @Test("S1: deadline after send -> 'may have been delivered', no interrupt, guard released")
  func deadlineAfterSend() async throws {
    var p = SettingsPatch()
    p.answerBudgetMs = 200
    let h = try await askHarness(settings: p)
    let r = await h.ask("你好")
    #expect(r.outcome == "no-reply:deadline")
    #expect(r.text == zh.noReplyInTime("拆解师"))
    #expect(!h.fake.requests.contains { $0.path.hasSuffix("/interrupt") })
    #expect(await h.svc.inFlight.isEmpty)
  }

  @Test("second concurrent request to the same bot is rejected immediately")
  func inFlight() async throws {
    let h = try await askHarness()
    h.fake.autoReply(SID, ms: 100)
    async let first = h.ask("一")
    await sleepMs(20)
    let second = await h.ask("二")
    #expect(second.outcome == "in-flight")
    #expect(await first.outcome == "answered")
    #expect(h.fake.posts.count == 1)
  }

  @Test("auth failure, 4xx send rejection, transient poll errors")
  func errors() async throws {
    do {
      let h = try await askHarness(key: "wrong")
      let r = await h.ask("你好")
      #expect(r.outcome == "auth-failed")
      #expect(r.text == zh.authFailed)
    }
    do {
      let h = try await askHarness()
      h.fake.intercept = { method, what, _, _ in what == "messages" && method == "POST" ? .status(400) : nil }
      let r = await h.ask("你好")
      #expect(r.outcome == "upstream")
      #expect(r.text == zh.upstreamDown)
    }
    do {
      let h = try await askHarness()
      let gets = Counter()
      h.fake.intercept = { method, what, _, _ in what == "entries" && method == "GET" && gets.next() == 2 ? .status(503) : nil }
      h.fake.autoReply(SID, ms: 50)
      let r = await h.ask("你好")
      #expect(r.outcome == "answered")
      #expect(r.timings["poll_errors"] == 1)
    }
  }

  @Test("no credential: the turn says sign in again and sends nothing")
  func noCredential() async throws {
    let h = try await askHarness()
    let svc = AskService(config: h.config, state: h.state, bdk: { nil })
    let r = await svc.ask(AskRequest(botKey: "chai", text: "hi", lang: .zhCN))
    #expect(r.outcome == "auth-failed")
    #expect(r.text == zh.authFailed)
    #expect(h.fake.posts.isEmpty)
  }

  @Test("BDK delivery: an unknown value stops waiting at once; a missing field still waits for the reply")
  func delivery() async throws {
    do {
      var p = SettingsPatch()
      p.answerBudgetMs = 5000
      let h = try await askHarness(settings: p)
      h.fake.delivery = "rejected_by_harness"
      h.fake.autoReply(SID)
      let t0 = Date()
      let r = await h.ask("你好")
      #expect(r.outcome == "not-accepted")
      #expect(r.text == zh.noReplyInTime("拆解师"), "never claims it was not delivered")
      #expect(Date().timeIntervalSince(t0) < 1, "no wait until the deadline")
      #expect(h.askLog?["delivery"] == "unknown")
      #expect(!h.logs.json.contains("rejected_by_harness"))
    }
    for value in ["synthetic_private_value", "sk-live: not/allowed!", String(repeating: "x", count: 500)] {
      let h = try await askHarness()
      h.fake.delivery = value
      #expect(await h.ask("你好").outcome == "not-accepted")
      #expect(h.askLog?["delivery"] == "unknown")
      #expect(!h.logs.json.contains(value))
    }
    for value in [nil, "duplicate"] as [String?] {
      let h = try await askHarness()
      h.fake.delivery = value
      h.fake.autoReply(SID, text: "到了。")
      #expect(await h.ask("你好").outcome == "answered")
    }
  }

  @Test("BDK review B2: a multi-part turn speaks only the proved first delivery; the trace is logged")
  func multiPart() async throws {
    let h = try await askHarness()
    h.fake.autoReply(SID, text: "第一段。", more: [PRIVATE], gapMs: 5)
    let r = await h.ask("讲讲")
    #expect(r.text == "第一段。")
    #expect(!r.text.contains(PRIVATE) && !h.logs.json.contains(PRIVATE))
    guard case .string(let turns)? = h.askLog?["turns"] else {
      Issue.record("no turn trace")
      return
    }
    #expect(turns.wholeMatch(of: /[BI?]+/) != nil)
  }

  @Test("input validation and unknown bots")
  func validation() async throws {
    var p = SettingsPatch()
    p.maxQuestionChars = 5
    let h = try await askHarness(settings: p)
    #expect(await h.ask("x", bot: "nope").outcome == "not-configured")
    #expect(await h.ask("   ").outcome == "empty")
    #expect(await h.ask("一二三四五六").outcome == "too-long")
    try await h.config.putBot(Bot(key: "fresh", name: "新", sessionId: "1", strictEcho: true))
    let r = await h.svc.ask(AskRequest(botKey: "fresh", text: "hi"))
    #expect(r.outcome == "not-configured", "no cold sync in the voice path")
    #expect(r.text == Messages.of(.en).botNotConfigured, "English when no language is given")
    #expect(h.fake.posts.isEmpty)
  }

  @Test("T3: a turn for a session that is no longer the bot's is not configured")
  func sessionMismatch() async throws {
    let h = try await askHarness()
    h.fake.autoReply(SID)
    let r = await h.svc.ask(AskRequest(botKey: "chai", sessionId: "999", text: "hi"))
    #expect(r.outcome == "not-configured")
    #expect(h.fake.posts.isEmpty)
  }

  @Test("S4: English Shortcut -> English envelope and messages; Chinese stays Chinese")
  func english() async throws {
    let h = try await askHarness()
    h.fake.setIdle(SID, false)
    #expect(await h.ask("hi", lang: .en).text == Messages.of(.en).busy("拆解师"))
    h.fake.setIdle(SID, true)
    h.fake.autoReply(SID, text: "It is three.")
    let r = await h.ask("What time is it?", lang: .en)
    #expect(r.text == "It is three.")
    #expect(h.fake.posts[0].text.firstMatch(of: /^\[Homebot voice · hb:[0-9a-f]{12} · en\]\nWhat time is it\?\n/) != nil)
    #expect(h.fake.posts[0].text.contains("Then answer in English,") && h.fake.posts[0].text.contains("answer in English even if the question is in another language."))
  }

  @Test("busy rule: idle=false, inFlight=true or queued>0 each count as busy")
  func busyRule() async throws {
    #expect(isBusy(Turn(idle: .bool(true), inFlight: .bool(false), queued: .number(0))) == false)
    #expect(isBusy(Turn(idle: .bool(false), inFlight: .bool(false), queued: .number(0))))
    #expect(isBusy(Turn(idle: .bool(true), inFlight: .bool(true), queued: .number(0))))
    #expect(isBusy(Turn(idle: .bool(true), inFlight: .bool(false), queued: .number(2))))
    let h = try await askHarness()
    h.fake.setQueued(SID, 1)
    #expect(await h.ask("hi").outcome == "busy")
    #expect(h.fake.posts.isEmpty)
  }

  @Test("S6: a transient baseline failure is retried within the deadline")
  func baselineRetry() async throws {
    let h = try await askHarness()
    let gets = Counter()
    h.fake.intercept = { method, what, _, _ in what == "entries" && method == "GET" && gets.next() == 1 ? .status(503) : nil }
    h.fake.autoReply(SID)
    let r = await h.ask("你好")
    #expect(r.outcome == "answered")
    #expect(h.fake.posts.count == 1)
  }

  @Test("S6: baseline auth errors are not retried")
  func baselineAuth() async throws {
    let h = try await askHarness()
    let gets = Counter()
    h.fake.intercept = { _, what, _, _ in
      if what == "entries" { _ = gets.next() }
      return what == "entries" ? .status(401) : nil
    }
    let r = await h.ask("hi")
    #expect(r.outcome == "auth-failed")
    #expect(gets.value == 1)
  }

  @Test("S2: slow cursor persistence never delays the response")
  func slowPersist() async throws {
    var p = SettingsPatch()
    p.answerBudgetMs = 100
    let box = StateBox()
    let h = try await askHarness(settings: p) { key, cursor, maxSeq, sid in
      await sleepMs(400)
      try await box.state?.setCursor(key, cursor: cursor, maxSeq: maxSeq, sessionId: sid)
    }
    box.state = h.state
    let t0 = Date()
    let r = await h.ask("hi")
    #expect(r.outcome == "no-reply:deadline")
    #expect(Date().timeIntervalSince(t0) < 0.3, "responded despite a 400 ms write")
    await h.svc.flush()
    let cur = try must(await h.state.cursor("chai"))
    #expect(try Seq.parse(cur.cursor) > Seq.parse("1000"))
  }

  @Test("S2: cursor writes from two requests never overlap or reorder, even when the first is slowest")
  func orderedPersist() async throws {
    var p = SettingsPatch()
    p.answerBudgetMs = 100
    let box = StateBox()
    let events = EventList()
    let n = Counter()
    let h = try await askHarness(settings: p) { key, cursor, maxSeq, sid in
      let i = n.next()
      events.add("start \(i) \(cursor)")
      await sleepMs(i == 1 ? 300 : 5)
      try await box.state?.setCursor(key, cursor: cursor, maxSeq: maxSeq, sessionId: sid)
      events.add("end \(i)")
    }
    box.state = h.state
    _ = await h.ask("one")
    h.fake.add(SID, kind: "send-message", text: "desktop activity between requests")
    _ = await h.ask("two")
    await h.svc.flush()
    let ev = events.items
    #expect(n.value >= 2)
    for i in 0..<n.value {
      #expect(ev[2 * i].hasPrefix("start \(i + 1) "))
      #expect(ev[2 * i + 1] == "end \(i + 1)", "each write finishes before the next starts")
    }
    let cursors = ev.filter { $0.hasPrefix("start") }.map { try! Seq.parse(String($0.split(separator: " ")[2])) }
    #expect(zip(cursors, cursors.dropFirst()).allSatisfy { $0 <= $1 }, "cursors are written in non-decreasing order")
  }

  @Test("S2: a failing cursor write is logged, not thrown")
  func failingPersist() async throws {
    var p = SettingsPatch()
    p.answerBudgetMs = 50
    let h = try await askHarness(settings: p) { _, _, _, _ in throw StoreError("EACCES synthetic") }
    _ = await h.ask("hi")
    await h.svc.flush()
    #expect(h.logs.first("persist-error") != nil)
  }

  @Test("A1: protocol fragments, the key and the token never reach speech")
  func filter() async throws {
    let h = try await askHarness()
    h.fake.autoReply(SID, text: "好的 hb:0123456789ab [hb:fedcba987654] 结束 \(FakeGrokBot.key)。")
    let svc = h.svc
    let r = await svc.ask(AskRequest(botKey: "chai", text: "hi", lang: .zhCN, redact: ["token-plaintext-xyz"]))
    #expect(r.outcome == "answered")
    #expect(r.text == "好的 结束 。")
    #expect(!r.text.contains("hb:") && !r.text.contains(FakeGrokBot.key))
  }

  @Test("S25: a reply its voice can't read is never spoken; the token's language says so instead")
  func unreadableScript() async throws {
    let h = try await askHarness()
    h.fake.autoReply(SID, text: "我是 homebot，陪你琢磨软件点子的工程师朋友。")
    let en = await h.ask("你是谁", lang: .en)
    #expect(en.outcome == "unspeakable" && en.reason == "script")
    #expect(en.text == Messages.of(.en).unspeakable)
    h.fake.autoReply(SID, text: "我是 homebot。")
    #expect(await h.ask("你是谁", lang: .zhCN).text == "我是 homebot。", "a Chinese voice reads it, Latin words included")
  }

  @Test("S25: which letters each voice can read")
  func readableScripts() {
    let cases: [(String, ReplyLang, Bool)] = [
      ("我是 homebot。", .en, false), ("我是 homebot。", .zhCN, true), ("It is three.", .zhTW, true), ("Café crème, 3 €", .fr, true),
      ("コーヒーを飲む", .ja, true), ("コーヒー", .zhCN, false), ("안녕하세요 OK", .ko, true), ("안녕", .ja, false),
      ("Привет, OK", .ru, true), ("Привет", .de, false), ("", .en, true),
    ]
    for (s, lang, ok) in cases { #expect(Speech.readable(s, by: lang) == ok, "\(lang): \(s)") }
  }

  @Test("S25: the bot's end mark is read, never spoken; a bare mark gets Homebot's goodbye")
  func endMark() async throws {
    let h = try await askHarness()
    h.fake.autoReply(SID, text: "[end] 好的，回头见。")
    let r = await h.ask("先这样吧")
    #expect(r.outcome == "answered" && r.ended && r.text == "好的，回头见。")
    h.fake.autoReply(SID, text: "[end]")
    let bare = await h.ask("先这样吧")
    #expect(bare.outcome == "answered" && bare.ended && bare.text == Messages.of(.zhCN).goodbye)
    h.fake.autoReply(SID, text: "好的 [end] 回头见。")
    let mid = await h.ask("先这样吧")
    #expect(mid.outcome == "answered" && !mid.ended && mid.text == "好的 回头见。", "mid-text: not an end, and not spoken")
    h.fake.autoReply(SID, text: "[end] bye", echo: false)
    let untagged = await h.ask("先这样吧")
    #expect(!untagged.ended && untagged.outcome != "answered", "no tag: refused as before, never an end")
  }

  @Test("a reply that is only protocol text is unspeakable")
  func onlyProtocol() async throws {
    let h = try await askHarness()
    h.fake.autoReply(SID, text: "[hb:fedcba987654]")
    let r = await h.ask("hi")
    #expect(r.outcome == "unspeakable")
  }

  @Test("credential results are reported for the turn's generation")
  func credentialReport() async throws {
    let h = try await askHarness()
    let seen = EventList()
    let client = h.fake.client()
    let wrong = h.fake.client(key: "wrong")
    let ok = AskService(config: h.config, state: h.state, bdk: { BdkSession(client: client, generation: 7) }, onCredential: { g, a in seen.add("\(g) \(a)") })
    h.fake.autoReply(SID)
    _ = await ok.ask(AskRequest(botKey: "chai", text: "hi"))
    let bad = AskService(config: h.config, state: h.state, bdk: { BdkSession(client: wrong, generation: 8) }, onCredential: { g, a in seen.add("\(g) \(a)") })
    _ = await bad.ask(AskRequest(botKey: "chai", text: "hi"))
    #expect(seen.items == ["7 true", "8 false"])
  }
}

final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var n = 0
  func next() -> Int { lock.withLock { n += 1; return n } }
  var value: Int { lock.withLock { n } }
}

final class EventList: @unchecked Sendable {
  private let lock = NSLock()
  private var list: [String] = []
  func add(_ s: String) { lock.withLock { list.append(s) } }
  var items: [String] { lock.withLock { list } }
}

final class StateBox: @unchecked Sendable {
  private let lock = NSLock()
  private var _s: StateStore?
  var state: StateStore? {
    get { lock.withLock { _s } }
    set { lock.withLock { _s = newValue } }
  }
}
