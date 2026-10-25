// The entry flow's choosing phase (DESIGN §20.5) and the cancellation of a step's shared work
// (S1 open risk, Codex S1 review finding 4).
import Foundation
import Testing

@testable import HomebotCore

final class Pins: @unchecked Sendable {
  private let lock = NSLock()
  private var _pins: [BotGrant] = []
  private var _live: [EntryChoice]
  private var _refuse: Set<String> = []
  init(_ live: [EntryChoice]) { _live = live }
  var pins: [BotGrant] { lock.withLock { _pins } }
  var live: [EntryChoice] {
    get { lock.withLock { _live } }
    set { lock.withLock { _live = newValue } }
  }
  func refuse(_ key: String) { _ = lock.withLock { _refuse.insert(key) } }
  var context: EntryContext {
    EntryContext(choices: { self.live }, pin: { g in
      self.lock.withLock {
        if self._refuse.contains(g.key) { return false }
        self._pins.append(g)
        return true
      }
    })
  }
}

let chaiC = EntryChoice(key: "chai", sessionId: "1", name: "拆解师")
let kitchen = EntryChoice(key: "kitchen", sessionId: "2", name: "厨房")
let study = EntryChoice(key: "study", sessionId: "3", name: "书房助手")

struct EntryRun {
  let conv: Conv
  let pins: Pins
  let lang: ReplyLang

  func step(_ run: String, _ n: Int, _ text: String = "", last: Int = 10, bot: String? = nil) async -> StepReply {
    await conv.svc.step(ConversationStep(run: run, step: n, last: last, text: text, prompt: "", botKey: bot, sessionId: bot == nil ? nil : "1", tokenId: "tok", lang: lang, entry: pins.context))
  }
}

func entryRun(_ live: [EntryChoice], lang: ReplyLang = .zhCN, outcomes: [String] = [], stillGranted: @escaping @Sendable (String, BotGrant) async -> Bool = { _, _ in true }) -> EntryRun {
  EntryRun(conv: Conv(outcomes, stillGranted: stillGranted), pins: Pins(live), lang: lang)
}

@Suite("Entry flow (DESIGN §20.5)")
struct EntryTests {
  @Test("matching: normalization, numbers in each script, yes and no words")
  func words() {
    #expect(Chooser.norm(" 拆解师。") == "拆解师")
    #expect(Chooser.norm("Kitchen  Helper!") == "kitchenhelper")
    #expect(Chooser.number("2", .zhCN) == 2)
    #expect(Chooser.number("２", .zhCN) == 2, "full-width digits are NFKC-folded")
    #expect(Chooser.number("二", .zhCN) == 2)
    #expect(Chooser.number("第二个", .zhCN) == 2)
    #expect(Chooser.number("两号", .zhCN) == 2)
    #expect(Chooser.number("Number two.", .en) == 2)
    #expect(Chooser.number("2番", .ja) == 2)
    #expect(Chooser.number("두번째", .ko) == 2)
    #expect(Chooser.number("dos", .es) == 2)
    #expect(Chooser.number("10", .en) == nil)
    #expect(Chooser.number("twenty", .en) == nil)
    #expect(Chooser.isYes("是的。", .zhCN) && Chooser.isYes("Yes", .en) && Chooser.isYes("はい", .ja))
    #expect(Chooser.isNo("不对", .zhCN) && Chooser.isNo("No.", .en) && Chooser.isNo("nein", .de))
    #expect(!Chooser.isNo("不对劲吗", .zhCN), "only the whole utterance counts")
  }

  @Test("matching: exact name or alias, then number, then a close name with a clear margin")
  func match() {
    let items = [EntryChoice(key: "a", sessionId: "1", name: "Kitchen Helper"), EntryChoice(key: "b", sessionId: "2", name: "Study", aliases: ["Library"]), EntryChoice(key: "c", sessionId: "3", name: "Garage Assistant")]
    #expect(Chooser.match("kitchen helper", items, .en) == .exact(0))
    #expect(Chooser.match("Library", items, .en) == .exact(1))
    #expect(Chooser.match("three", items, .en) == .exact(2))
    #expect(Chooser.match("4", items, .en) == .none, "no fourth entry")
    #expect(Chooser.match("kitchen helpr", items, .en) == .fuzzy(0))
    #expect(Chooser.match("garage asistent", items, .en) == .fuzzy(2), "two edits in 15 characters")
    #expect(Chooser.match("stdy", items, .en) == .fuzzy(1), "five letters allow one edit")
    #expect(Chooser.match("pizza", items, .en) == .none)
    #expect(Chooser.match("", items, .en) == .none)
  }

  @Test("matching: a close name needs a margin of 2 over the second best")
  func margin() {
    let items = [EntryChoice(key: "a", sessionId: "1", name: "Helper One"), EntryChoice(key: "b", sessionId: "2", name: "Helper Ono")]
    #expect(Chooser.match("helper onu", items, .en) == .none, "equally close to both")
  }

  @Test("Mandarin: a name written with other characters of the same sound is a close match, asked back")
  func soundsLike() {
    let items = [EntryChoice(key: "a", sessionId: "1", name: "拆解师"), EntryChoice(key: "b", sessionId: "2", name: "厨房"), EntryChoice(key: "c", sessionId: "3", name: "Grok Helper")]
    #expect(Chooser.match("拆姐诗", items, .zhCN) == .fuzzy(0), "chai jie shi")
    #expect(Chooser.match("出房", items, .zhCN) == .fuzzy(1), "chu fang")
    #expect(Chooser.match("拆姐诗", items, .zhTW) == .fuzzy(0))
    #expect(Chooser.match("拆姐诗", items, .ja) == .none, "the sound rule is for Mandarin only")
    #expect(Chooser.match("天气", items, .zhCN) == .none)
    #expect(Chooser.match("grok helpa", items, .zhCN) == .fuzzy(2), "a Latin name keeps the letter rule")
    let alike = [EntryChoice(key: "a", sessionId: "1", name: "厨房"), EntryChoice(key: "b", sessionId: "2", name: "出房")]
    #expect(Chooser.match("初芳", alike, .zhCN) == .none, "two names of the same sound are never guessed")
    #expect(Chooser.match("出房", alike, .zhCN) == .exact(1), "the exact characters still choose")
  }

  @Test("Codex S4 review 1-2: look-alikes and numbers are never guessed")
  func neverGuessed() {
    let alike = [EntryChoice(key: "a", sessionId: "1", name: "小智"), EntryChoice(key: "b", sessionId: "2", name: "小智"), EntryChoice(key: "c", sessionId: "3", name: "小志")]
    #expect(Chooser.match("晓志", alike, .zhCN) == .none, "a name that can't be chosen by name still competes for the margin")
    #expect(Chooser.match("小志", alike, .zhCN) == .exact(2))
    let numbered = [EntryChoice(key: "a", sessionId: "1", name: "第二个"), EntryChoice(key: "b", sessionId: "2", name: "厨房")]
    #expect(Chooser.match("第二个", numbered, .zhCN) == .exact(1), "a name that reads as a number means the number")
    #expect(Chooser.ambiguousNames(numbered, .zhCN) == ["第二个"])
    let wine = [EntryChoice(key: "a", sessionId: "1", name: "酒"), EntryChoice(key: "b", sessionId: "2", name: "厨房")]
    #expect(Chooser.match("九", wine, .zhCN) == .none, "an out-of-range number is no match, not a sound-alike name")
    let poem = [EntryChoice(key: "a", sessionId: "1", name: "诗"), EntryChoice(key: "b", sessionId: "2", name: "厨房")]
    #expect(Chooser.match("是", poem, .zhCN) == .none, "a yes word is never a name")
  }

  @Test("ambiguity: duplicate names, numbers, yes/no and end words are matchable by number only")
  func ambiguity() {
    let items = [EntryChoice(key: "a", sessionId: "1", name: "厨房"), EntryChoice(key: "b", sessionId: "2", name: "厨房"), EntryChoice(key: "c", sessionId: "3", name: "二"), EntryChoice(key: "d", sessionId: "4", name: "谢谢"), EntryChoice(key: "e", sessionId: "5", name: "好")]
    #expect(Chooser.ambiguousNames(items, .zhCN) == ["厨房", "厨房", "二", "谢谢", "好"])
    #expect(Chooser.match("厨房", items, .zhCN) == .none)
    #expect(Chooser.match("二", items, .zhCN) == .exact(1), "二 is the number two, never the bot named 二")
    #expect(Chooser.match("五", items, .zhCN) == .exact(4))
  }

  @Test("one live bot: pinned at step 0, its name said before the prompt")
  func single() async throws {
    let e = entryRun([chaiC])
    let s0 = await e.step("", 0)
    #expect(s0.response.say == "拆解师。想问什么？")
    #expect(s0.response.next == .listen && s0.response.mode == .v2)
    #expect(s0.activity?.outcome == "chosen")
    #expect(e.pins.pins == [chaiC.grant], "the pin step admits and activates the grant")
    let r1 = await e.step(s0.response.run, 1, "几点了")
    #expect(r1.response.say == "answer 1")
    #expect(e.conv.ask.calls.map { [$0.botKey, $0.sessionId ?? ""] } == [["chai", "1"]])
    #expect(r1.activity?.question == "几点了")
  }

  @Test("several bots: the menu, a name, then the question goes to that bot only")
  func choose() async throws {
    let e = entryRun([chaiC, kitchen])
    let s0 = await e.step("", 0)
    #expect(s0.response.say == "问哪个机器人？1 拆解师，2 厨房。")
    #expect(s0.activity == nil && e.pins.pins.isEmpty, "the menu activates nothing")
    let r1 = await e.step(s0.response.run, 1, "厨房。")
    #expect(r1.response.say == "厨房。想问什么？")
    #expect(r1.response.mode == .v2 && r1.response.next == .listen)
    #expect(r1.activity == StepActivity(outcome: "chosen", step: 1, botKey: "kitchen", botName: "厨房"))
    #expect(e.conv.ask.calls.isEmpty, "nothing is sent while choosing")
    let r2 = await e.step(s0.response.run, 2, "冰箱里有什么")
    #expect(r2.response.say == "answer 1")
    #expect(e.conv.ask.calls.map(\.botKey) == ["kitchen"])
    #expect(e.conv.ask.calls[0].sessionId == "2")
  }

  @Test("a number keeps the meaning it had when the menu was spoken")
  func snapshot() async throws {
    let e = entryRun([chaiC, kitchen])
    let s0 = await e.step("", 0)
    e.pins.live = [kitchen, chaiC]
    let r1 = await e.step(s0.response.run, 1, "第一个")
    #expect(r1.response.say == "拆解师。想问什么？")
    #expect(e.pins.pins == [chaiC.grant])
  }

  @Test("a chosen bot that no longer holds: the menu again from the live list, as a miss")
  func revalidate() async throws {
    let e = entryRun([chaiC, kitchen, study])
    let s0 = await e.step("", 0)
    e.pins.refuse("kitchen")
    e.pins.live = [chaiC, study]
    let r1 = await e.step(s0.response.run, 1, "2")
    #expect(r1.response.say == "问哪个机器人？1 拆解师，2 书房助手。")
    #expect(r1.activity?.outcome == "no-match")
    let r2 = await e.step(s0.response.run, 2, "2")
    #expect(r2.response.say == "书房助手。想问什么？", "the new snapshot's numbering")
    let e2 = entryRun([chaiC, kitchen])
    let t0 = await e2.step("", 0)
    _ = await e2.step(t0.response.run, 1, "披萨")
    e2.pins.refuse("kitchen")
    let t2 = await e2.step(t0.response.run, 2, "厨房")
    #expect(t2.response.say == "没有找到这个机器人。" && t2.response.next == .end, "a second miss ends the run")
  }

  @Test("two misses end the run; silence counts as a miss; an end word says goodbye")
  func misses() async throws {
    let e = entryRun([chaiC, kitchen])
    let s0 = await e.step("", 0)
    let r1 = await e.step(s0.response.run, 1, "")
    #expect(r1.response.say.hasPrefix("问哪个机器人？") && r1.response.next == .listen)
    let r2 = await e.step(s0.response.run, 2, "披萨")
    #expect(r2.response.say == "没有找到这个机器人。")
    #expect(r2.response.next == .end && r2.activity?.outcome == "no-match")
    let e2 = entryRun([chaiC, kitchen])
    let t0 = await e2.step("", 0)
    let bye = await e2.step(t0.response.run, 1, "再见")
    #expect(bye.response.say == "好的。" && bye.response.next == .end && bye.activity?.outcome == "end-word")
    #expect(e2.conv.ask.calls.isEmpty)
  }

  @Test("a close name is asked back; only yes continues")
  func fuzzy() async throws {
    let helper = EntryChoice(key: "kh", sessionId: "7", name: "Kitchen Helper")
    let garage = EntryChoice(key: "ga", sessionId: "8", name: "Garage")
    let e = entryRun([helper, garage], lang: .en)
    let s0 = await e.step("", 0)
    #expect(s0.response.say == "Which bot? 1 Kitchen Helper, 2 Garage.")
    let r1 = await e.step(s0.response.run, 1, "kitchen helpr")
    #expect(r1.response.say == "Did you mean Kitchen Helper?")
    #expect(r1.activity?.outcome == "confirm" && e.pins.pins.isEmpty)
    let r2 = await e.step(s0.response.run, 2, "yes")
    #expect(r2.response.say == "Kitchen Helper. What would you like to ask?")
    #expect(e.pins.pins == [helper.grant])
    let r3 = await e.step(s0.response.run, 3, "no", last: 10)
    #expect(r3.response.say == "answer 1", "after a yes, a 'no' is a question like any other")

    let n = entryRun([helper, garage], lang: .en)
    let t0 = await n.step("", 0)
    _ = await n.step(t0.response.run, 1, "kitchen helpr")
    let t2 = await n.step(t0.response.run, 2, "maybe")
    #expect(t2.response.say == "Which bot? 1 Kitchen Helper, 2 Garage.", "anything but yes goes back to the choice")
    #expect(n.pins.pins.isEmpty)
  }

  @Test("a 'no' right after an exact choice goes back to the menu, once")
  func backOnce() async throws {
    let e = entryRun([chaiC, kitchen])
    let s0 = await e.step("", 0)
    _ = await e.step(s0.response.run, 1, "拆解师")
    let r2 = await e.step(s0.response.run, 2, "不对")
    #expect(r2.response.say == "问哪个机器人？1 拆解师，2 厨房。")
    let r3 = await e.step(s0.response.run, 3, "厨房")
    #expect(r3.response.say == "厨房。想问什么？")
    let r4 = await e.step(s0.response.run, 4, "不是")
    #expect(r4.response.next == .end && r4.response.say == "没有找到这个机器人。")
    #expect(e.conv.ask.calls.isEmpty)
  }

  @Test("step cap: the last step's answer always ends the run, also while choosing")
  func cap() async throws {
    let e = entryRun([chaiC, kitchen])
    let s0 = await e.step("", 0, last: 1)
    #expect(s0.response.next == .end && s0.response.say == "没有找到这个机器人。")
    let f = entryRun([chaiC, kitchen])
    let t0 = await f.step("", 0, last: 2)
    let t1 = await f.step(t0.response.run, 1, "披萨", last: 2)
    #expect(t1.response.next == .listen)
    let t2 = await f.step(t0.response.run, 2, "厨房", last: 2)
    #expect(t2.response.next == .end, "a choice on the last step can't be followed by a question")
  }

  @Test("an entry run is pinned: a step naming a bot, or a changed retry, restarts")
  func pinned() async throws {
    let e = entryRun([chaiC, kitchen])
    let s0 = await e.step("", 0)
    let r1 = await e.step(s0.response.run, 1, "1")
    let again = await e.step(s0.response.run, 1, "1")
    #expect(again.response == r1.response && again.activity == nil, "a retry is answered from the cache and adds no record")
    #expect(e.pins.pins.count == 1, "a retry never pins twice")
    let other = await e.step(s0.response.run, 2, "几点了", bot: "kitchen")
    #expect(other.response.next == .end && other.response.say.contains("重新开始"))
  }

  @Test("rule 3: a pinned grant that is revoked ends the run before the bot is asked")
  func revoked() async throws {
    let held = Flag()
    held.set()
    let e = entryRun([chaiC, kitchen], stillGranted: { _, _ in !held.isSet })
    let s0 = await e.step("", 0)
    _ = await e.step(s0.response.run, 1, "拆解师")
    let r = await e.step(s0.response.run, 2, "几点了")
    #expect(r.response.say == zh.botNotConfigured)
    #expect(r.activity?.outcome == "revoked")
    #expect(e.conv.ask.calls.isEmpty)
  }

  @Test("no live grant: the entry run ends with the not-configured line")
  func none() async throws {
    let e = entryRun([])
    let s0 = await e.step("", 0)
    #expect(s0.response.next == .end && s0.response.say == zh.botNotConfigured)
  }

  @Test("Codex S1 finding 4: a client that leaves cancels the step's shared work; its retry gets the same outcome")
  func sharedWorkCancelled() async throws {
    let h = try await askHarness()
    let svc = h.svc
    let conv = ConversationService(ask: { await svc.ask($0) })
    h.fake.intercept = { _, what, _, _ in
      if what == "entries" { await sleepMs(100) }
      return nil
    }
    h.fake.autoReply(SID, ms: 1000)
    func step(_ run: String, _ n: Int, _ text: String, _ signal: CancelSignal?) async -> LoopResponse {
      await conv.handle(ConversationStep(run: run, step: n, last: 10, text: text, prompt: "q", botKey: "chai", sessionId: SID, tokenId: "tok", lang: .zhCN, signal: signal))
    }
    let s0 = await step("", 0, "", nil)
    let first = CancelSignal()
    async let r1 = step(s0.run, 1, "几点了", first)
    await sleepMs(30)
    first.cancel()
    let a = await r1
    #expect(a.say == zh.notSent && a.next == .end, "the baseline was still running: nothing was sent")
    let retry = await step(s0.run, 1, "几点了", CancelSignal())
    #expect(retry == a, "the retry shares the cancelled step's outcome")
    await sleepMs(200)
    #expect(h.fake.posts.isEmpty, "nothing reached the bot after the client left")
  }
}
