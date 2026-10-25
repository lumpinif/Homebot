// The single-entry Shortcut end to end, offline (DESIGN §20.5, S4): the Shortcut file Homebot
// builds is played by ShortcutRunner, action by action, against the real gateway over HTTP and
// the fake Grok Bot. Each test is a scripted spoken exchange: what the user says at each Ask for
// Input, and what Siri says back. Unverified here (S6, Felix's device test): Siri's transcription,
// its time limits for the extra round trips, and how a HomePod plays an Ask for Input prompt.
import Foundation
import Testing

@testable import HomebotCore
@testable import HomebotGateway
import HomebotTestSupport

let chaiEn = Bot(key: "chai", name: "Chai", sessionId: "14752726", strictEcho: true)
let kitchenEn = Bot(key: "kitchen", name: "Kitchen Helper", sessionId: "555", strictEcho: true)
/// A Latin-named bot with a Mandarin alias: the alias is what a Chinese HomePod can hear.
let grok = Bot(key: "grok", name: "Grok Helper", sessionId: "777", strictEcho: true, aliases: ["格罗克"])

struct Exchange {
  let made: MadeShortcut
  /// The Shortcut as built (its file is deleted on first use, like on the phone).
  let workflow: PlistValue
  let runner: ShortcutRunner

  var lines: [ShortcutRunner.Line] { runner.transcript }
  /// What Siri said, in order (questions and speech), without the user's turns.
  var siri: [String] {
    lines.compactMap {
      switch $0 {
      case .asks(let s), .speaks(let s, _): s
      case .user: nil
      }
    }
  }
}

extension HostHarness {
  /// Build the entry Shortcut for `bots` with the app's own builder, then play it with `answers`.
  func entry(_ bots: [Bot], siriLang: String = "zh-CN", answers: [String]) async throws -> Exchange {
    let s = try await stores()
    let profile = try Profile.entry(siriLang: siriLang, taken: Profile.takenPhrases(await s.tokens.list().map { ($0.id, $0.label, $0.state) }))
    let made = try await ShortcutMaker.make(tokens: s.tokens, lifecycle: s.lifecycle, bots: bots, profile: profile, baseUrl: "http://felix-mac.local:8787", kind: .entry)
    let workflow = try ShortcutRunner.load(made.file)
    return Exchange(made: made, workflow: workflow, runner: try await play(workflow, answers: answers))
  }

  /// Run a built Shortcut once more, as a second "Hey Siri, …".
  func play(_ workflow: PlistValue, answers: [String]) async throws -> ShortcutRunner {
    var runner = try ShortcutRunner(workflow, answers: answers)
    let port = self.port
    try await runner.run { r in
      // The Shortcut calls the Mac by its Bonjour name; the test listener is on loopback.
      let path = URLComponents(string: r.url)?.path ?? "/"
      #expect(r.method == "POST" && path == "/v1/ask")
      return await RawHTTP.send(port: port, method: r.method, path: path, headers: r.headers, body: RawHTTP.json(r.json)).text
    }
    #expect(runner.remaining.isEmpty, "unused answers: \(runner.remaining)")
    return runner
  }

  func outcomes() throws -> [String] {
    (try control(["cmd": "activity"])["records"] as? [[String: Any]] ?? []).reversed().compactMap { $0["outcome"] as? String }
  }
}

@Suite("Entry Shortcut, played offline (DESIGN §20.5)", .serialized)
struct EntryFlowTests {
  let zh = Messages.of(.zhCN)
  let en = Messages.of(.en)
  let zt = ChooserText.of(.zhCN)
  let et = ChooserText.of(.en)

  @Test("one bot: its name, then the question; Siri keeps listening until an end word")
  func oneBot() async throws {
    let h = try await HostHarness.start(bots: [chai])
    h.fake.autoReply(chai.sessionId, text: "现在三点。", reportsBusy: false)
    let x = try await h.entry([chai], answers: ["几点了", "谢谢"])
    #expect(x.made.name == "家庭助手", "the entry phrase is the product phrase, never a bot name")
    #expect(x.siri == ["拆解师。想问什么？", "现在三点。", zh.more, zh.goodbye])
    #expect(x.lines.last == .speaks(zh.goodbye, lang: "zh-CN"), "spoken in the Siri language's voice")
    #expect(x.runner.requests.allSatisfy { $0.json["bot"] == nil }, "the entry Shortcut never names a bot")
    #expect(x.runner.requests.map { $0.json["step"] } == ["0", "1", "2"])
    #expect(h.fake.posts.map(\.sid) == [chai.sessionId])
    #expect(try await h.state(x.made.tokenId) == .active)
    #expect(try h.outcomes() == ["chosen", "answered", "end-word"])
    await h.stop()
  }

  @Test("two bots, a clear choice by name (English): menu, the name spoken back, then the question")
  func clearChoice() async throws {
    let h = try await HostHarness.start(bots: [chaiEn, kitchenEn])
    h.fake.autoReply(kitchenEn.sessionId, text: "There is milk.", reportsBusy: false)
    let x = try await h.entry([chaiEn, kitchenEn], siriLang: "en-US", answers: ["Kitchen helper.", "What's in the fridge?", "never mind"])
    #expect(x.made.name == "Grok Bot")
    #expect(x.siri == ["Which bot? 1 Chai, 2 Kitchen Helper.", "Kitchen Helper. What would you like to ask?", "There is milk.", en.more, en.goodbye])
    #expect(h.fake.posts.map(\.sid) == [kitchenEn.sessionId], "only the chosen bot got a message")
    #expect(h.fake.posts.first?.text.contains("What's in the fridge?") == true)
    #expect(try h.outcomes() == ["chosen", "answered", "end-word"])
    await h.stop()
  }

  @Test("two bots, chosen by number (Chinese)")
  func byNumber() async throws {
    let h = try await HostHarness.start(bots: [chai, kitchen])
    h.fake.autoReply(kitchen.sessionId, text: "冰箱里有牛奶。", reportsBusy: false)
    let x = try await h.entry([chai, kitchen], answers: ["第二个", "冰箱里有什么", "再见"])
    #expect(x.siri == ["问哪个机器人？1 拆解师，2 厨房。", "厨房。想问什么？", "冰箱里有牛奶。", zh.more, zh.goodbye])
    #expect(h.fake.posts.map(\.sid) == [kitchen.sessionId])
    await h.stop()
  }

  @Test("a mis-heard Chinese name (same sound, other characters) is asked back; yes continues")
  func misheardChinese() async throws {
    let h = try await HostHarness.start(bots: [chai, kitchen])
    h.fake.autoReply(chai.sessionId, text: "现在三点。", reportsBusy: false)
    let x = try await h.entry([chai, kitchen], answers: ["拆姐诗", "是的", "几点了", "再见"])
    #expect(x.siri == [zt.menu([EntryChoice(chai), EntryChoice(kitchen)]), "是拆解师吗？", "拆解师。想问什么？", "现在三点。", zh.more, zh.goodbye])
    #expect(h.fake.posts.map(\.sid) == [chai.sessionId])
    #expect(try h.outcomes() == ["confirm", "chosen", "answered", "end-word"])
    await h.stop()
  }

  @Test("a mis-heard English name is asked back; anything but yes goes back to the menu")
  func misheardEnglish() async throws {
    let h = try await HostHarness.start(bots: [chaiEn, kitchenEn])
    h.fake.autoReply(chaiEn.sessionId, text: "It is three.", reportsBusy: false)
    let x = try await h.entry([chaiEn, kitchenEn], siriLang: "en-US", answers: ["kitchen helpers", "no", "chai", "what time is it", "goodbye"])
    let menu = "Which bot? 1 Chai, 2 Kitchen Helper."
    #expect(x.siri == [menu, "Did you mean Kitchen Helper?", menu, "Chai. What would you like to ask?", "It is three.", en.more, en.goodbye])
    #expect(h.fake.posts.map(\.sid) == [chaiEn.sessionId], "nothing went to the bot that was only guessed")
    await h.stop()
  }

  @Test("no confident match: the menu once more, then Siri stops; nothing is sent and the token stays pending")
  func noMatch() async throws {
    let h = try await HostHarness.start(bots: [chai, kitchen])
    let x = try await h.entry([chai, kitchen], answers: ["天气怎么样", "随便"])
    let menu = zt.menu([EntryChoice(chai), EntryChoice(kitchen)])
    #expect(x.siri == [menu, menu, zt.notFound])
    #expect(h.fake.posts.isEmpty)
    #expect(try await h.state(x.made.tokenId) == .pending, "choosing never activates a token (T5)")
    #expect(try h.outcomes() == ["no-match", "no-match"])
    let recs = try h.control(["cmd": "activity"])["records"] as? [[String: Any]] ?? []
    #expect(recs.allSatisfy { $0["question"] == nil }, "what was said while choosing is never stored")
    await h.stop()
  }

  @Test("two names that sound the same are never guessed: the menu again, then a number works")
  func soundAlike() async throws {
    let chu = Bot(key: "chu", name: "出房", sessionId: "888", strictEcho: true)
    let h = try await HostHarness.start(bots: [kitchen, chu])
    h.fake.autoReply(chu.sessionId, text: "好的。", reportsBusy: false)
    let x = try await h.entry([kitchen, chu], answers: ["初芳", "二", "开灯", "结束"])
    let menu = zt.menu([EntryChoice(kitchen), EntryChoice(chu)])
    #expect(x.siri == [menu, menu, "出房。想问什么？", "好的。", zh.more, zh.goodbye])
    #expect(h.fake.posts.map(\.sid) == [chu.sessionId])
    await h.stop()
  }

  @Test("a follow-up stays on the chosen bot, even when it says another bot's name")
  func followUpPinned() async throws {
    let h = try await HostHarness.start(bots: [chai, kitchen])
    h.fake.autoReply(chai.sessionId, text: "好的。", reportsBusy: false)
    let x = try await h.entry([chai, kitchen], answers: ["拆解师", "几点了", "厨房", "没事了"])
    #expect(x.siri == [zt.menu([EntryChoice(chai), EntryChoice(kitchen)]), "拆解师。想问什么？", "好的。", zh.more, "好的。", zh.more, zh.goodbye])
    #expect(h.fake.posts.map(\.sid) == [chai.sessionId, chai.sessionId], "both turns went to the chosen bot")
    #expect(h.fake.posts.last?.text.contains("厨房") == true, "the bot's name after the choice is a question, not a new choice")
    #expect(try h.outcomes() == ["chosen", "answered", "answered", "end-word"])
    await h.stop()
  }

  @Test("'no' right after the choice goes back to the menu once")
  func noAfterChoice() async throws {
    let h = try await HostHarness.start(bots: [chai, kitchen])
    h.fake.autoReply(chai.sessionId, text: "好的。", reportsBusy: false)
    let x = try await h.entry([chai, kitchen], answers: ["厨房", "不对", "拆解师", "开灯", "再见"])
    let menu = zt.menu([EntryChoice(chai), EntryChoice(kitchen)])
    #expect(x.siri == [menu, "厨房。想问什么？", menu, "拆解师。想问什么？", "好的。", zh.more, zh.goodbye])
    #expect(h.fake.posts.map(\.sid) == [chai.sessionId])
    await h.stop()
  }

  @Test("a Latin-named bot on a Chinese HomePod: its Mandarin alias is spoken and matched")
  func alias() async throws {
    let h = try await HostHarness.start(bots: [chai, grok])
    h.fake.autoReply(grok.sessionId, text: "你好。", reportsBusy: false)
    let x = try await h.entry([chai, grok], answers: ["格罗克", "你好", "再见"])
    #expect(x.siri == ["问哪个机器人？1 拆解师，2 格罗克。", "格罗克。想问什么？", "你好。", zh.more, zh.goodbye])
    #expect(h.fake.posts.map(\.sid) == [grok.sessionId])
    await h.stop()
  }

  @Test("silence while choosing counts as a miss; an end word says goodbye")
  func silenceAndEnd() async throws {
    let h = try await HostHarness.start(bots: [chai, kitchen])
    let x = try await h.entry([chai, kitchen], answers: ["", "退出"])
    let menu = zt.menu([EntryChoice(chai), EntryChoice(kitchen)])
    #expect(x.siri == [menu, menu, zh.goodbye])
    #expect(h.fake.posts.isEmpty)
    await h.stop()
  }

  @Test("the step cap counts the choosing steps: after a choice and eight questions the tenth step ends the run, and is spoken")
  func stepCap() async throws {
    let h = try await HostHarness.start(bots: [chai, kitchen])
    h.fake.autoReply(chai.sessionId, text: "好的。", reportsBusy: false)
    // A choice, then eight more questions: the last answer is spoken by the Otherwise branch.
    let x = try await h.entry([chai, kitchen], answers: ["拆解师"] + (1...9).map { "问题\($0)" })
    #expect(x.runner.requests.count == 11, "step 0 and ten steps")
    #expect(x.lines.last == .speaks("好的。", lang: "zh-CN"))
    #expect(h.fake.posts.count == 9)
    await h.stop()
  }

  @Test("interim progress messages: the tagged reply is spoken in the pinned run; activity keeps counts only")
  func interimReply() async throws {
    let h = try await HostHarness.start(bots: [chai, kitchen])
    h.fake.autoReply(chai.sessionId, text: "你最新一封邮件来自 Vercel。", interim: ["正在查你最新的 Gmail。"], gapMs: 60)
    let x = try await h.entry([chai, kitchen], answers: ["拆解师", "我最近一封Gmail邮件是什么", "再见"])
    #expect(x.siri == [zt.menu([EntryChoice(chai), EntryChoice(kitchen)]), "拆解师。想问什么？", "你最新一封邮件来自 Vercel。", zh.more, zh.goodbye])
    #expect(!x.siri.contains { $0.contains("正在查") }, "an interim message is never spoken")
    let recs = try h.control(["cmd": "activity"])["records"] as? [[String: Any]] ?? []
    let answered = try #require(recs.first { $0["outcome"] as? String == "answered" })
    #expect(answered["delivery"] as? Int == 2 && answered["interim"] as? Int == 1)
    #expect(!String(describing: recs).contains("正在查"), "interim text is never stored")
    await h.stop()
  }

  @Test("interim only: a pinned run with only untagged output is refused (O5) with the ownership wording, and ends")
  func interimOnly() async throws {
    let h = try await HostHarness.start(bots: [chai, kitchen])
    h.fake.autoReply(chai.sessionId, text: "正在查你最新的 Gmail。", echo: false)
    let x = try await h.entry([chai, kitchen], answers: ["拆解师", "我最近一封Gmail邮件是什么"])
    #expect(x.siri.last == zh.refused)
    #expect(!zh.refused.contains("隐私"), "the refusal names ownership, not privacy")
    #expect(!x.siri.contains { $0.contains("正在查") })
    #expect(try h.outcomes() == ["chosen", "refused"])
    await h.stop()
  }

  @Test("a reply tagged for another request is refused in the pinned run")
  func foreignTag() async throws {
    let h = try await HostHarness.start(bots: [chai, kitchen])
    let fake = h.fake
    fake.setOnMessage { sid, _ in
      Task {
        try? await Task.sleep(nanoseconds: 20_000_000)
        _ = fake.add(sid, kind: "send-message", text: "[hb:ffffffffffff] 别人的回答")
      }
    }
    let x = try await h.entry([chai, kitchen], answers: ["拆解师", "几点了"])
    #expect(x.siri.last == zh.refused)
    #expect(!x.siri.contains { $0.contains("别人的回答") })
    await h.stop()
  }

  @Test("adding a bot to the set changes the menu with no new Shortcut (T4); removing one narrows it")
  func setEdit() async throws {
    let h = try await HostHarness.start(bots: [chai, kitchen])
    let x = try await h.entry([chai], answers: ["再见"])
    #expect(x.siri.first == "拆解师。想问什么？")
    let s = try await h.stores()
    try await s.lifecycle.setBots(x.made.tokenId, [chai, kitchen])
    let menu = zt.menu([EntryChoice(chai), EntryChoice(kitchen)])
    let wider = try await h.play(x.workflow, answers: ["退出"])
    #expect(wider.transcript.first == .asks(menu))
    _ = try await s.lifecycle.remove(chai.key)
    let narrower = try await h.play(x.workflow, answers: ["退出"])
    #expect(narrower.transcript.first == .asks("厨房。想问什么？"), "an entry token left with one bot says that bot's name first")
    await h.stop()
  }
}
