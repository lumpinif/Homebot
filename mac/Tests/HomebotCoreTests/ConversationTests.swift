// Ported from test/conversation.test.ts (the ConversationService, run and Shortcut parts; the
// follow-up wait inside AskService and the HTTP contract move to S2 with those modules), plus
// DESIGN §20.5 rules 3 and 4 (pinned grant, identical retries).
import Foundation
import Testing

@testable import HomebotCore

/// A fake ask service: answers from `outcomes` in order and records each request.
final class FakeAsk: @unchecked Sendable {
  private let lock = NSLock()
  private var outcomes: [String]
  private var _calls: [AskRequest] = []
  var calls: [AskRequest] { lock.withLock { _calls } }

  init(_ outcomes: [String] = []) { self.outcomes = outcomes }

  var fn: AskFn {
    { r in
      self.lock.withLock {
        self._calls.append(r)
        let outcome = self.outcomes.isEmpty ? "answered" : self.outcomes.removeFirst()
        return AskResult(text: outcome == "answered" ? "answer \(self._calls.count)" : "refusal \(outcome)", outcome: outcome)
      }
    }
  }
}

struct Conv {
  let svc: ConversationService
  let ask: FakeAsk
  let logs: LogSink

  init(_ outcomes: [String] = [], followupIdleMs: Int = 0, stillGranted: @escaping @Sendable (String, BotGrant) async -> Bool = { _, _ in true }) {
    ask = FakeAsk(outcomes)
    logs = LogSink()
    svc = ConversationService(ask: ask.fn, log: logs.fn, followupIdleMs: { followupIdleMs }, stillGranted: stillGranted)
  }

  func step(_ run: String, _ n: Int, _ text: String = "", last: Int = Conversation.steps, botKey: String = "chai", sessionId: String? = "1", prompt: String = "想问什么？") async -> LoopResponse {
    await svc.handle(ConversationStep(run: run, step: n, last: last, text: text, prompt: prompt, botKey: botKey, sessionId: sessionId, tokenId: "tok", lang: .zhCN))
  }
}

@Suite("Conversation runs")
struct ConversationTests {
  @Test("the first prompt is the Shortcut's question; answers keep listening")
  func basics() async {
    let c = Conv(followupIdleMs: 3000)
    let s0 = await c.step("", 0)
    #expect([s0.say, s0.mode.rawValue, s0.next.rawValue] == ["想问什么？", "v2", "listen"])
    let r1 = await c.step(s0.run, 1, "明天天气怎么样")
    #expect([r1.say, r1.mode.rawValue, r1.ask, r1.next.rawValue] == ["answer 1", "v1", "还有吗？", "listen"])
    let r2 = await c.step(s0.run, 2, "那后天呢")
    #expect(r2.next == .listen)
    #expect(c.ask.calls.map { [$0.turn ?? -1, $0.waitIdleMs] } == [[1, 0], [2, 3000]], "only a follow-up to an answered turn may wait")
    #expect(c.ask.calls.allSatisfy { $0.sessionId == "1" }, "every turn uses the authorized session")
  }

  @Test("a refusal, error or timeout ends the run, and no later step is taken")
  func refusalEnds() async {
    let c = Conv(["answered", "refused"], followupIdleMs: 3000)
    let s0 = await c.step("", 0)
    _ = await c.step(s0.run, 1, "一")
    let r2 = await c.step(s0.run, 2, "二")
    #expect([r2.say, r2.next.rawValue] == ["refusal refused", "end"])
    let r3 = await c.step(s0.run, 3, "三")
    #expect(r3.next == .end)
    #expect(r3.say.contains("重新开始"))
    #expect(c.ask.calls.count == 2, "nothing is sent after the run ended")
  }

  @Test("end words and silence end the run without reaching the bot", arguments: ["谢谢。", " 再见 ", "", "  "])
  func endWords(said: String) async {
    let c = Conv()
    let s0 = await c.step("", 0)
    let r = await c.step(s0.run, 1, said)
    #expect([r.say, r.next.rawValue] == ["好的。", "end"])
    #expect(c.ask.calls.isEmpty)
  }

  @Test("only the whole utterance is an end word")
  func wholeUtterance() async {
    let c = Conv()
    let s0 = await c.step("", 0)
    #expect(await c.step(s0.run, 1, "谢谢你帮我查天气").next == .listen)
    #expect(c.ask.calls.count == 1)
  }

  @Test("the last step's answer ends the run, so it is spoken (DESIGN §18.2)")
  func cap() async {
    let c = Conv()
    let s0 = await c.step("", 0, last: 2)
    #expect(await c.step(s0.run, 1, "一", last: 2).next == .listen)
    let r2 = await c.step(s0.run, 2, "二", last: 99)
    #expect([r2.say, r2.next.rawValue] == ["answer 2", "end"], "the cap sent at the start holds")
  }

  @Test("retries are answered once; foreign runs and other bots restart; run ids and speech are never logged")
  func retries() async {
    let c = Conv()
    let s0 = await c.step("", 0)
    async let a = c.step(s0.run, 1, "一")
    async let b = c.step(s0.run, 1, "一")
    let (ra, rb) = await (a, b)
    #expect(ra == rb)
    #expect(c.ask.calls.count == 1, "a retried step never asks the bot twice")
    let other = await c.step(s0.run, 2, "二", botKey: "kitchen")
    #expect(other.next == .end)
    #expect(c.ask.calls.count == 1, "a run belongs to one bot")
    let forged = await c.step("SECRET_FROM_REQUEST", 1, "x")
    #expect(forged.next == .end && forged.run == "")
    #expect(!c.logs.json.contains("SECRET"))
    #expect(!c.logs.json.contains("一"), "what was said is never logged")
    #expect(!c.logs.json.contains(s0.run))
  }

  @Test("a step that throws ends the run; its retry gets the same answer (review S2)")
  func throwing() async {
    let calls = LockedBox(0)
    let svc = ConversationService(ask: { _ in
      calls.mutate { $0 += 1 }
      throw BdkError(message: "state refresh failed", kind: .upstream, status: nil)
    })
    func step(_ run: String, _ n: Int, _ text: String = "") async -> LoopResponse {
      await svc.handle(ConversationStep(run: run, step: n, last: 10, text: text, prompt: "", botKey: "chai", tokenId: "tok", lang: .en))
    }
    let s0 = await step("", 0)
    #expect(s0.say == Messages.of(.en).more, "an empty prompt falls back to the 'more' line")
    let r1 = await step(s0.run, 1, "hello")
    #expect(r1.next == .end)
    #expect(await step(s0.run, 1, "hello") == r1)
    #expect(await step(s0.run, 2, "again").next == .end)
    #expect(calls.value == 1, "nothing more reaches the bot after the failed step")
  }

  @Test("a retry for another bot is not answered from the cache (review N1)")
  func otherBotRetry() async {
    let c = Conv()
    let s0 = await c.step("", 0)
    let r1 = await c.step(s0.run, 1, "一")
    let other = await c.step(s0.run, 1, "一", botKey: "kitchen")
    #expect(other != r1)
    #expect(other.next == .end)
  }

  @Test("rule 4: a repeated step with a different question is not a retry")
  func changedRetry() async {
    let c = Conv()
    let s0 = await c.step("", 0)
    let r1 = await c.step(s0.run, 1, "几点了")
    let changed = await c.step(s0.run, 1, "我的银行密码是什么")
    #expect(changed != r1)
    #expect(changed.next == .end)
    #expect(changed.say.contains("重新开始"))
    #expect(c.ask.calls.count == 1, "the new question never reaches the bot or gets the old answer")
  }

  @Test("rule 3: a run is pinned to key and session; another session of the same key restarts")
  func pinnedSession() async {
    let c = Conv()
    let s0 = await c.step("", 0, sessionId: "1")
    let r1 = await c.step(s0.run, 1, "一", sessionId: "1")
    let moved = await c.step(s0.run, 1, "一", sessionId: "2")
    #expect(moved != r1, "the cached answer is never returned for another conversation")
    #expect(await c.step(s0.run, 2, "二", sessionId: "2").next == .end)
    #expect(c.ask.calls.count == 1)
  }

  @Test("rule 3: a revoked grant ends the run, also for a cached retry")
  func revoked() async {
    let granted = LockedBox(true)
    let c = Conv(stillGranted: { _, g in granted.value && g == BotGrant(key: "chai", sessionId: "1") })
    let s0 = await c.step("", 0)
    let r1 = await c.step(s0.run, 1, "一")
    #expect(r1.say == "answer 1")
    granted.mutate { $0 = false }
    let retry = await c.step(s0.run, 1, "一")
    #expect(retry.say == Messages.of(.zhCN).botNotConfigured, "no cached text after revocation")
    #expect(retry.next == .end)
    #expect(c.logs.json.contains("revoked"))
    granted.mutate { $0 = true }
    #expect(await c.step(s0.run, 2, "二").next == .end, "the run stays ended")
    #expect(c.ask.calls.count == 1)
  }

  @Test("rule 3: another token's request for a run never ends it (Codex S2 review 4)")
  func foreignTokenCannotEndRun() async {
    let svc = ConversationService(ask: { _ in AskResult(text: "the answer", outcome: "answered") }, stillGranted: { tok, g in tok == "tok" && g.key == "chai" })
    func step(_ run: String, _ n: Int, _ text: String, bot: String, token: String) async -> LoopResponse {
      await svc.handle(ConversationStep(run: run, step: n, last: 10, text: text, prompt: "q", botKey: bot, sessionId: "1", tokenId: token, lang: .en))
    }
    let s0 = await step("", 0, "", bot: "chai", token: "tok")
    let foreign = await step(s0.run, 1, "hello", bot: "kitchen", token: "other")
    #expect(foreign.next == .end && foreign.say != "the answer", "refused")
    let mine = await step(s0.run, 1, "hello", bot: "chai", token: "tok")
    #expect(mine.say == "the answer", "the owner's run goes on")
  }

  @Test("rule 3: a grant revoked while the bot is answering suppresses that answer, also for a waiting retry")
  func revokedWhileAnswering() async throws {
    let granted = LockedBox(true)
    let release = LockedBox(false)
    let svc = ConversationService(ask: { _ in
      while !release.value { try await Task.sleep(nanoseconds: 1_000_000) }
      return AskResult(text: "the answer", outcome: "answered")
    }, stillGranted: { _, _ in granted.value })
    func step(_ run: String, _ n: Int, _ text: String = "") async -> LoopResponse {
      await svc.handle(ConversationStep(run: run, step: n, last: 10, text: text, prompt: "q", botKey: "chai", sessionId: "1", tokenId: "tok", lang: .en))
    }
    let s0 = await step("", 0)
    async let first = step(s0.run, 1, "hello")
    try await Task.sleep(nanoseconds: 20_000_000)
    async let retry = step(s0.run, 1, "hello")
    try await Task.sleep(nanoseconds: 20_000_000)
    granted.mutate { $0 = false }
    release.mutate { $0 = true }
    let (a, b) = await (first, retry)
    #expect(a.say == Messages.of(.en).botNotConfigured && b.say == Messages.of(.en).botNotConfigured)
    #expect(a.next == .end)
  }

  @Test("restart answers end the run: no later step is taken (Codex S1 review 5)")
  func restartEndsRun() async {
    let c = Conv()
    let s0 = await c.step("", 0)
    _ = await c.step(s0.run, 1, "一")
    #expect(await c.step(s0.run, 1, "changed").next == .end)
    #expect(await c.step(s0.run, 2, "二").next == .end)
    let c2 = Conv()
    let r0 = await c2.step("", 0)
    #expect(await c2.step(r0.run, 1, "一", botKey: "kitchen").next == .end)
    #expect(await c2.step(r0.run, 1, "一").next == .end, "the run named another bot and ended")
    #expect(c.ask.calls.count == 1 && c2.ask.calls.isEmpty)
  }

  @Test("envelope: every language asks for the token's language, whatever the question's (DECISIONS item 31)")
  func envelopeReplyLanguage() {
    let ask: [ReplyLang: String] = [
      .en: "answer in English even if", .es: "responde en español aunque", .fr: "réponds en français même si", .de: "antworte auf Deutsch, auch wenn", .it: "rispondi in italiano anche se",
      .ptBR: "responda em português mesmo que", .ru: "отвечай по-русски, даже если", .ja: "質問が別の言語でも日本語で", .ko: "다른 언어여도 한국어로", .zhCN: "也要用中文回答", .zhTW: "也要用繁體中文回答",
    ]
    #expect(Set(ask.keys) == Set(ReplyLang.allCases))
    for l in ReplyLang.allCases {
      let e = Envelope.build(id: "abc", text: "What time is it?", lang: l, strictEcho: true)
      #expect(e.contains(ask[l]!), "\(l)")
      #expect(e.hasPrefix("[Homebot voice · hb:abc · \(l.rawValue)]"), "the head names the reply language")
    }
  }

  @Test("envelope: a conversation turn tells the bot the turn and that only its first message is heard")
  func envelopeTurn() {
    let zh = Envelope.build(id: "abc", text: "那后天呢", lang: .zhCN, strictEcho: true, turn: 2)
    #expect(zh.contains("第 2 轮"))
    #expect(zh.contains("只会听到你这一轮的第一条消息"))
    #expect(Envelope.build(id: "abc", text: "and after", lang: .en, strictEcho: true, turn: 3).contains("turn 3 of a voice conversation"))
    #expect(!Envelope.build(id: "abc", text: "x", lang: .en, strictEcho: true).contains("conversation"))
  }

  @Test("conversation Shortcut: the loop posts to /v1/ask with v 2, the bot and the first question")
  func shortcut() throws {
    let wf = try ShortcutBuilder().conversationShortcut(baseUrl: "http://felix-mac.local:8787", botKey: "chai", token: "TOKEN", prompt: "想问拆解师什么？", speakLang: "zh-CN")
    let xml = try Plist.xml(wf)
    let actions = try #require(wf["WFWorkflowActions"]?.arrayValue)
    let posts = actions.filter { $0["WFWorkflowActionIdentifier"]?.stringValue == "is.workflow.actions.downloadurl" }
    #expect(posts.count == 2, "the start step and the loop step")
    for p in posts { #expect(p["WFWorkflowActionParameters"]?["WFURL"]?.stringValue == "http://felix-mac.local:8787/v1/ask") }
    #expect(xml.contains("想问拆解师什么？"))
    let rep = actions.first { $0["WFWorkflowActionIdentifier"]?.stringValue == "is.workflow.actions.repeat.count" }
    #expect(rep?["WFWorkflowActionParameters"]?["WFRepeatCount"] == .integer(Int64(Conversation.steps)))
    #expect(try plutilLint(xml))
  }
}

@Suite("Run store")
struct RunStoreTests {
  @Test("run ids are 16 lowercase hex; anything else is never looked up")
  func ids() async {
    let runs = RunStore<Int, String>()
    let (id, r) = await runs.start(tokenId: "t", state: 0) { "start \($0.prefix(2))" }
    #expect(RunStore<Int, String>.isRunId(id))
    #expect(!RunStore<Int, String>.isRunId(id.uppercased()))
    #expect(!RunStore<Int, String>.isRunId("x"))
    _ = await r.value
    #expect(await runs.check(id, tokenId: "other", step: 1).kind == "unknown", "another token's run")
    #expect(await runs.check(id, tokenId: "t", step: 3).kind == "unknown", "a skipped step")
  }

  @Test("a next step waits until the previous response is ready; runs expire")
  func earlyAndExpiry() async throws {
    let clock = Clock(0)
    let runs = RunStore<Int, String>(ttlMs: 1000, now: clock.fn)
    let gate = LockedBox(false)
    let (id, _) = await runs.start(tokenId: "t", state: 0) { _ in
      while !gate.value { try? await Task.sleep(nanoseconds: 1_000_000) }
      return "s0"
    }
    #expect(await runs.check(id, tokenId: "t", step: 1).kind == "early")
    gate.mutate { $0 = true }
    for _ in 0..<1000 where await runs.check(id, tokenId: "t", step: 1).kind != "next" { try await Task.sleep(nanoseconds: 1_000_000) }
    #expect(await runs.check(id, tokenId: "t", step: 1).kind == "next")
    clock.now = 1001
    #expect(await runs.check(id, tokenId: "t", step: 1).kind == "unknown")
    #expect(await runs.size == 0)
  }
}
