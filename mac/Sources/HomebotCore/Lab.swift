// Device-experiment mode (DESIGN §19): scripted steps for the lab Shortcut, served on /v1/lab
// only while the gateway runs with the lab on. It never contacts a bot. What Felix says is
// matched against the expected sentence and then discarded: the log holds ids, lengths, match
// results and timings only (design review v8 B3). Ported from src/core/lab.ts.
import Foundation

public enum LabScenario: String, Sendable, CaseIterable, Codable {
  case e1 = "E1", e1b = "E1b", e2 = "E2", e3 = "E3", e4 = "E4", e5 = "E5", e6 = "E6", e7 = "E7"
}

public enum Lab {
  /// E7 answer delays (s) when `lab use E7` names none.
  public static let defaultDelays = [8, 12, 16, 20, 25, 30]

  /// What the lab Shortcut hears when the gateway runs without the lab.
  public static func off(_ lang: ReplyLang) -> String {
    lang == .zhCN ? "实验模式没有打开。请在 Mac 上用 homebot start --lab 启动。" : "The lab is off. Start Homebot on the Mac with: homebot start --lab."
  }

  public struct Expect: Sendable, Equatable {
    /// The whole sentence; only this, in full, counts as "full".
    public var whole: String
    public var head: String
    public var tail: String

    public init(whole: String, head: String, tail: String) {
      self.whole = whole
      self.head = head
      self.tail = tail
    }

    static func word(_ w: String) -> Expect { Expect(whole: w, head: w, tail: w) }
  }

  static func norm(_ s: String) -> String {
    s.precomposedStringWithCompatibilityMapping.lowercased().replacingOccurrences(of: #"[\p{P}\p{S}\s]"#, with: "", options: .regularExpression)
  }

  /// full: the whole sentence arrived. cut: its start arrived, not the whole. partial: only its
  /// end arrived. other: neither.
  public static func match(_ received: String, _ expect: Expect?) -> String {
    let r = norm(received)
    if r.isEmpty { return "empty" }
    guard let e = expect else { return "n/a" }
    if r.contains(norm(e.whole)) { return "full" }
    if r.contains(norm(e.head)) { return "cut" }
    if r.contains(norm(e.tail)) { return "partial" }
    return "other"
  }

  public struct State: Sendable, Equatable {
    public var scenario: LabScenario
    /// Changes on every `lab use`; the gateway restarts the E7 delay list when it does.
    public var version: Double
    public var delays: [Int]
  }

  /// The chosen experiment; a missing or bad file falls back to E1 with the default delays.
  public static func readState(_ file: URL) -> State {
    let raw = (try? FileUtil.readIfExists(file)).flatMap { $0 }.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
    var delays = defaultDelays
    if let d = raw["delays"] as? [Any], d.allSatisfy({ isDelay($0) }) { delays = d.map { ($0 as! NSNumber).intValue } }
    let scenario = (raw["scenario"] as? String).flatMap(LabScenario.init(rawValue:)) ?? .e1
    let version = (raw["version"] as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue } ?? 0
    return State(scenario: scenario, version: version, delays: delays)
  }

  static func isDelay(_ v: Any) -> Bool {
    guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
    let d = n.doubleValue
    return d == d.rounded() && d > 0 && d <= 120
  }

  public static func writeState(_ file: URL, scenario: LabScenario, delays: [Int]? = nil, now: Double = Date().timeIntervalSince1970 * 1000) throws {
    struct Out: Encodable { let scenario: String; let version: Double; let delays: [Int] }
    try FileUtil.writeJSON(file, Out(scenario: scenario.rawValue, version: now, delays: delays ?? defaultDelays))
  }

  struct Spec: Sendable {
    var say: String
    var mode: LoopResponse.Mode?
    /// What the user is asked to say in reply to this step.
    var expect: Expect?
    var delayMs: Int?

    init(_ say: String, mode: LoopResponse.Mode? = nil, expect: Expect? = nil, delayMs: Int? = nil) {
      self.say = say
      self.mode = mode
      self.expect = expect
      self.delayMs = delayMs
    }
  }

  struct Text: Sendable {
    var ask: String
    var pause: Expect
    var ok: Expect
    var no: Expect
    /// The last word of a long answer; saying it back proves the whole answer was read.
    var marker: Expect
    var restart: String
    var done: @Sendable (LabScenario) -> String
    var waited: @Sendable (Int) -> String
    var e1: [String]
    var e1b: [String]
    var e2: [String]
    var e3: [String]
    var e4: [String]
    var e5First: String
    var e5Answer: @Sendable (Int) -> String
    var e5Last: String
    var e6: [String]
    var e7: String
  }

  static let longZh =
    "下面是一段比较长的回答，用来测试 Siri 能不能把它完整读出来。今天的天气总体不错，上午有一些云，中午以后会转晴，气温大约在二十度到二十六度之间，" +
    "傍晚可能会有一点风。如果你打算出门散步，下午四点以后比较合适，记得带一件薄外套。晚上的空气质量预计良好，适合开窗通风。明天的天气和今天差不多，" +
    "后天可能会有小雨，出门前最好再看一下预报。这段话到这里就结束了。"
  static let longEn =
    "Here is a longer answer, to test whether Siri reads all of it. The weather today is mostly fine: some clouds in the morning, clearing after noon, " +
    "with temperatures between twenty and twenty-six degrees and a little wind in the evening. If you plan a walk, late afternoon is best; bring a light jacket. " +
    "Air quality tonight should be good. Tomorrow looks similar, and there may be light rain the day after. That is the end of this answer."

  /// The digit of a scenario id ("E1b" -> 1).
  static func number(_ id: LabScenario) -> Int { Int(String(id.rawValue.dropFirst().prefix(1))) ?? 0 }

  /// The lab is scripted in English and Mandarin only; any other Siri language runs in English.
  static func text(_ lang: ReplyLang) -> Text { lang == .zhCN ? zh : en }

  static let zh = Text(
    ask: "请说。",
    pause: Expect(whole: "明天我想去公园散步，然后去超市买菜", head: "明天我想去公园散步", tail: "然后去超市买菜"),
    ok: .word("好"),
    no: .word("不用了"),
    marker: .word("西瓜"),
    restart: "这次实验已经结束了，请重新说“家庭实验”。",
    done: { id in
      let digits = Array("一二三四五六七")
      let n = number(id)
      return "实验\(n >= 1 && n <= digits.count ? String(digits[n - 1]) : id.rawValue)\(id.rawValue.hasSuffix("b") ? "乙" : "")结束。"
    },
    waited: { "等了\($0)秒。" },
    e1: ["实验一：这一轮请不要说话，等它自己结束。", "收到了空的回答，快捷指令没有自己结束。实验一结束。"],
    e1b: ["实验一乙：这一轮请说“好”。", "收到了。这一轮请不要说话，等它自己结束。", "收到了空的回答，快捷指令没有自己结束。实验一乙结束。"],
    e2: [
      "实验二，第一次：请正常读这句话，中间不要停：明天我想去公园散步，然后去超市买菜。",
      "第二次：同一句话，在“散步”后面停一秒。",
      "第三次：在“散步”后面停三秒。",
      "第四次：在“散步”后面停六秒。",
    ],
    e3: ["实验三：先按住 HomePod 顶部不放，再读这句话，在“散步”后面停两秒，说完再松手：明天我想去公园散步，然后去超市买菜。", "再来一次，同样按住。"],
    e4: [
      "实验四，第一部分：这是一句短回答。听完请说“好”。",
      "这是一句短回答，作为提问读出来。听完请说“好”。",
      "\(longZh)最后一个词是西瓜。请说出最后一个词。",
      "\(longZh)这一段是作为提问读出来的。最后一个词是西瓜。请说出最后一个词。",
      "\(longZh)\(longZh)这一段更长，作为提问读出来。最后一个词是西瓜。请说出最后一个词。",
    ],
    e5First: "实验五：一次长一点的对话，一共六轮。每轮随便说一句话。",
    e5Answer: { "这是第\($0)轮的回答，模拟机器人想了八秒。请再随便说一句。" },
    e5Last: "这是最后一轮的回答。实验五结束。",
    e6: ["实验六：请回答“不用了”。", "收到了“不用了”，快捷指令没有自己结束。实验六结束。"],
    e7: "实验七：随便说一句话，然后等着。"
  )

  static let en = Text(
    ask: "Go ahead.",
    pause: Expect(whole: "tomorrow I want to walk in the park and then buy some groceries", head: "tomorrow I want to walk in the park", tail: "buy some groceries"),
    ok: .word("okay"),
    no: .word("no"),
    marker: .word("watermelon"),
    restart: "This test run has ended. Please say the lab phrase again.",
    done: { id in
      let words = ["one", "two", "three", "four", "five", "six", "seven"]
      let n = number(id)
      return "Test \(n >= 1 && n <= words.count ? words[n - 1] : id.rawValue)\(id.rawValue.hasSuffix("b") ? " B" : "") is done."
    },
    waited: { "Waited \($0) seconds." },
    e1: ["Test one: say nothing this time, and let it end by itself.", "An empty answer arrived, and the Shortcut didn't stop by itself. Test one is done."],
    e1b: ["Test one B: say okay this time.", "Got it. Now say nothing, and let it end by itself.", "An empty answer arrived, and the Shortcut didn't stop by itself. Test one B is done."],
    e2: [
      "Test two, first try: read this without a pause: tomorrow I want to walk in the park, and then buy some groceries.",
      "Second try: the same sentence, with a one-second pause after park.",
      "Third try: a three-second pause after park.",
      "Fourth try: a six-second pause after park.",
    ],
    e3: ["Test three: press and hold the top of the HomePod, then read the sentence with a two-second pause after park, and let go when done: tomorrow I want to walk in the park, and then buy some groceries.", "Once more, holding the top."],
    e4: [
      "Test four, part one: this is a short answer. Say okay when you've heard it.",
      "This is a short answer, read as the question. Say okay when you've heard it.",
      "\(longEn) The last word is watermelon. Say the last word.",
      "\(longEn) This one was read as the question. The last word is watermelon. Say the last word.",
      "\(longEn) \(longEn) This even longer one was read as the question. The last word is watermelon. Say the last word.",
    ],
    e5First: "Test five: a longer conversation, six turns. Say anything each time.",
    e5Answer: { "This is answer \($0); the bot took eight seconds. Say anything again." },
    e5Last: "This is the last answer. Test five is done.",
    e6: ["Test six: please answer no.", "I got your no, so the Shortcut didn't stop by itself. Test six is done."],
    e7: "Test seven: say anything, then wait."
  )

  /// The steps of one scenario: specs[0] answers the start step, specs[k] answers step k.
  static func scenario(_ id: LabScenario, _ lang: ReplyLang, delaySec: Int) -> [Spec] {
    let t = text(lang)
    let done = Spec(t.done(id))
    switch id {
    // E1 and E1b are separate runs: if silence stops the Shortcut, the first run cannot reach a
    // second condition (milestone review S5).
    case .e1: return [Spec(t.e1[0]), Spec(t.e1[1])]
    case .e1b: return [Spec(t.e1b[0], expect: t.ok), Spec(t.e1b[1]), Spec(t.e1b[2])]
    case .e2: return t.e2.map { Spec($0, expect: t.pause) } + [done]
    case .e3: return t.e3.map { Spec($0, expect: t.pause) } + [done]
    case .e4:
      return [
        Spec(t.e4[0], mode: .v1, expect: t.ok),
        Spec(t.e4[1], mode: .v2, expect: t.ok),
        Spec(t.e4[2], mode: .v1, expect: t.marker),
        Spec(t.e4[3], mode: .v2, expect: t.marker),
        Spec(t.e4[4], mode: .v2, expect: t.marker),
        done,
      ]
    case .e5: return [Spec(t.e5First)] + (1...5).map { Spec(t.e5Answer($0), delayMs: 8000) } + [Spec(t.e5Last, delayMs: 8000)]
    case .e6: return [Spec(t.e6[0], expect: t.no), Spec(t.e6[1])]
    case .e7: return [Spec(t.e7), Spec(t.waited(delaySec), delayMs: delaySec * 1000)]
    }
  }
}

public struct LabStep: Sendable {
  public var run: String
  public var step: Int
  public var last: Int
  public var text: String
  public var tokenId: String
  public var lang: ReplyLang
  public var signal: CancelSignal?

  public init(run: String, step: Int, last: Int, text: String, tokenId: String, lang: ReplyLang, signal: CancelSignal? = nil) {
    self.run = run
    self.step = step
    self.last = last
    self.text = text
    self.tokenId = tokenId
    self.lang = lang
    self.signal = signal
  }
}

public actor LabService {
  struct RunState: Sendable {
    var scenario: LabScenario
    var specs: [Lab.Spec]
    /// The Shortcut's step cap, as sent at the start; later steps cannot change it.
    var last: Int
    /// When the previous response was ready (for the gap to the next step).
    var sentAt: Double
  }

  let runs: RunStore<RunState, LoopResponse>
  let file: URL
  let log: LogFn
  let now: @Sendable () -> Double
  /// Scale for scripted delays (tests use a small value).
  let delayUnit: Double
  var version: Double = -1
  var delayIdx = 0

  public init(file: URL, log: @escaping LogFn = { _ in }, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }, delayUnit: Double = 1) {
    self.file = file
    self.log = log
    self.now = now
    self.delayUnit = delayUnit
    runs = RunStore(now: now)
  }

  public func handle(_ s: LabStep) async -> LoopResponse {
    let t = Lab.text(s.lang)
    let log = self.log
    if s.step == 0 {
      let st = Lab.readState(file)
      if st.version != version {
        version = st.version
        delayIdx = 0
      }
      let delay = st.delays.isEmpty ? 8 : st.delays[delayIdx % st.delays.count]
      delayIdx += 1
      let specs = Lab.scenario(st.scenario, s.lang, delaySec: delay)
      let end = specs.count <= 1 || s.last <= 0
      let first = specs[0]
      let started = await runs.start(tokenId: s.tokenId, state: RunState(scenario: st.scenario, specs: specs, last: s.last, sentAt: now())) { id in
        LabService.respond(first, id, t, end)
      }
      if end { await runs.finish(started.id) }
      log(["event": "lab", "scenario": .string(st.scenario.rawValue), "run": .string(String(started.id.prefix(6))), "step": 0])
      return await started.response.value
    }
    // Only an id this gateway could have issued is looked up or logged (milestone review S6).
    let run = s.run
    guard RunStore<RunState, LoopResponse>.isRunId(run) else {
      log(["event": "lab", "run": "invalid", "step": .int(s.step), "unknown": true])
      return LoopResponse(say: t.restart, ask: t.ask, mode: .v1, next: .end, run: "")
    }
    let runs = self.runs
    let now = self.now
    let unit = delayUnit
    let step = s.step
    let text = s.text
    let signal = s.signal
    let claim = await runs.claim(run, tokenId: s.tokenId, step: step, accept: { _ in true }) { st in
      let prev = step - 1 < st.specs.count ? st.specs[step - 1] : nil
      let spec = step < st.specs.count ? st.specs[step] : Lab.Spec(t.done(st.scenario))
      var entry: LogEvent = [
        "event": "lab",
        "scenario": .string(st.scenario.rawValue),
        "run": .string(String(run.prefix(6))),
        "step": .int(step),
        "mode": .string((prev?.mode ?? .v1).rawValue),
        "recv_len": .int(text.trimmingCharacters(in: jsWhitespace).unicodeScalars.count),
        "match": .string(Lab.match(text, prev?.expect)),
        "gap_ms": .int(Int(now() - st.sentAt)),
      ]
      // `text` is not used after this point and never logged.
      let end = step >= st.specs.count - 1 || step >= st.last
      if end { await runs.finish(run) }
      if let d = spec.delayMs {
        let t0 = now()
        _ = await (signal ?? CancelSignal()).sleep(ms: Int(Double(d) * unit))
        entry["delay_ms"] = .int(d)
        if signal?.isCancelled == true { entry["client_gave_up_ms"] = .int(Int(now() - t0)) }
      }
      log(entry)
      let sent = now()
      await runs.update(run) { $0.sentAt = sent }
      return LabService.respond(spec, run, t, end)
    }
    switch claim {
    case .taken(let task): return await task.value
    case .refused(.repeat(let task, _)):
      log(["event": "lab", "run": .string(String(run.prefix(6))), "step": .int(step), "repeat": true])
      return await task.value // the stored response of this run's own step
    case .refused(let c):
      log(["event": "lab", "run": .string(String(run.prefix(6))), "step": .int(step), "unknown": .string(c.kind)])
      return LoopResponse(say: t.restart, ask: t.ask, mode: .v1, next: .end, run: run)
    }
  }

  static func respond(_ spec: Lab.Spec?, _ run: String, _ t: Lab.Text, _ end: Bool) -> LoopResponse {
    LoopResponse(say: spec?.say ?? "", ask: t.ask, mode: spec?.mode ?? .v1, next: end ? .end : .listen, run: run)
  }
}
