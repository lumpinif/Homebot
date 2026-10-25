// Ported from test/lab.test.ts: the device-experiment lab (DESIGN §19.1), offline and over HTTP.
// The runs and the lab Shortcut build are covered in MakeTests.
import Foundation
import Testing

@testable import HomebotCore
@testable import HomebotGateway
import HomebotTestSupport

struct LabHarness {
  let svc: LabService
  let file: URL
  let logs: LogSink

  static func make(_ scenario: LabScenario, delays: [Int]? = nil) throws -> LabHarness {
    let file = try tmpDir().appendingPathComponent("lab.json")
    try Lab.writeState(file, scenario: scenario, delays: delays)
    let logs = LogSink()
    return LabHarness(svc: LabService(file: file, log: logs.fn, delayUnit: 0.001), file: file, logs: logs)
  }

  func step(_ run: String, _ n: Int, _ text: String = "", last: Int = ShortcutBuilder.labSteps, signal: CancelSignal? = nil) async -> LoopResponse {
    await svc.handle(LabStep(run: run, step: n, last: last, text: text, tokenId: "tok", lang: .zhCN, signal: signal))
  }

  /// Lab log events of steps after the start.
  var steps: [LogEvent] { logs.events.filter { $0["event"] == "lab" && ($0["step"].flatMap { if case .int(let n) = $0 { n } else { nil } } ?? 0) > 0 } }
}

@Suite("Lab")
struct LabTests {
  @Test("lab: sentence matching tells full, cut, other and empty apart")
  func matching() {
    let e = Lab.Expect(whole: "明天我想去公园散步，然后去超市买菜", head: "明天我想去公园散步", tail: "然后去超市买菜")
    #expect(Lab.match("明天我想去公园散步，然后去超市买菜。", e) == "full")
    #expect(Lab.match("明天我想去公园散步", e) == "cut")
    #expect(Lab.match("今天天气怎么样", e) == "other")
    #expect(Lab.match("明天我想去公园，然后去超市买菜", e) == "partial", "a missing middle is never full")
    #expect(Lab.match("  ", e) == "empty")
    #expect(Lab.match("随便", nil) == "n/a")
    let en = Lab.Expect(whole: "tomorrow I want to walk in the park and then buy some groceries", head: "tomorrow I want to walk in the park", tail: "buy some groceries")
    #expect(Lab.match("Tomorrow I want to walk in the park, and then buy some groceries.", en) == "full")
    #expect(Lab.match("Tomorrow I want to walk in the park.", en) == "cut")
    #expect(Lab.match("tom buy some groceries", en) == "partial", "review S7: only the end arrived")
  }

  @Test("lab E2: matches each try, logs no text, ends after the last try")
  func e2() async throws {
    let h = try LabHarness.make(.e2)
    let s0 = await h.step("", 0)
    #expect(s0.next == .listen)
    #expect(s0.say.contains("实验二"))
    let said = ["明天我想去公园散步然后去超市买菜", "明天我想去公园散步", "明天我想去公园散步然后去超市买菜", "我的银行卡密码"]
    var out: [LoopResponse] = []
    for (i, text) in said.enumerated() { out.append(await h.step(s0.run, i + 1, text)) }
    #expect(out.map(\.next) == [.listen, .listen, .listen, .end])
    #expect(out[3].say.contains("实验二结束"))
    #expect(h.steps.map { $0["match"] } == ["full", "cut", "full", "other"])
    #expect(h.steps.map { $0["recv_len"] } == [.int(16), .int(9), .int(16), .int(7)])
    for text in said { #expect(!h.logs.json.contains(text), "what was said never reaches the log") }
  }

  @Test("lab: the last step always ends the run, so its answer is spoken (review B2)")
  func lastStep() async throws {
    let h = try LabHarness.make(.e5)
    let s0 = await h.step("", 0, last: 2)
    #expect(await h.step(s0.run, 1, "一", last: 2).next == .listen)
    let r2 = await h.step(s0.run, 2, "二", last: 2)
    #expect(r2.next == .end)
    #expect(r2.say.contains("第2轮"), "the answer to the last step is the one spoken")
  }

  @Test("lab: the cap is the one sent at the start; an ended run takes no later step (review S4)")
  func cap() async throws {
    let h = try LabHarness.make(.e5)
    let s0 = await h.step("", 0, last: 1)
    #expect(await h.step(s0.run, 1, "一", last: 10).next == .end)
    let after = await h.step(s0.run, 2, "二", last: 10)
    #expect(after.next == .end)
    #expect(after.say.contains("重新说"))
  }

  @Test("lab: a run id the gateway did not issue is never logged (review S6)")
  func foreignRun() async throws {
    let h = try LabHarness.make(.e1)
    let r = await h.step("SECRET_FROM_REQUEST", 1, "x")
    #expect(r.next == .end)
    #expect(r.run == "")
    #expect(!h.logs.json.contains("SECRET"))
    #expect(h.logs.events.last?["run"] == "invalid")
  }

  @Test("lab E1 / E1b: silence first, and silence after an answer, are separate runs (review S5)")
  func e1() async throws {
    do {
      let h = try LabHarness.make(.e1)
      let s0 = await h.step("", 0)
      let r1 = await h.step(s0.run, 1, "")
      #expect(r1.next == .end)
      #expect(r1.say.contains("实验一结束"))
    }
    let h = try LabHarness.make(.e1b)
    let s0 = await h.step("", 0)
    #expect(s0.say.contains("请说“好”"))
    #expect(await h.step(s0.run, 1, "好").next == .listen)
    let r2 = await h.step(s0.run, 2, "")
    #expect(r2.next == .end)
    #expect(r2.say.contains("实验一乙结束"))
    #expect(h.logs.events.compactMap { $0["match"] } == ["full", "empty"])
  }

  @Test("lab: unknown runs end with a restart hint; a repeated step is answered once")
  func unknownAndRepeat() async throws {
    let h = try LabHarness.make(.e1)
    let lost = await h.step("deadbeefdeadbeef", 3, "x")
    #expect(lost.next == .end)
    #expect(lost.say.contains("重新说“家庭实验”"))
    let s0 = await h.step("", 0)
    async let a = h.step(s0.run, 1, "")
    async let b = h.step(s0.run, 1, "")
    let (ra, rb) = await (a, b)
    #expect(ra == rb)
    #expect(h.logs.events.filter { $0["step"] == .int(1) && $0["match"] != nil }.count == 1, "one result for a retried step")
    #expect(h.logs.events.filter { $0["repeat"] != nil }.count == 1)
  }

  @Test("lab E4: the response names how to speak each answer (V1 / V2)")
  func e4() async throws {
    let h = try LabHarness.make(.e4)
    let s0 = await h.step("", 0)
    var modes = [s0.mode]
    for i in 1...4 { modes.append(await h.step(s0.run, i, i < 3 ? "好" : "西瓜").mode) }
    #expect(modes == [.v1, .v2, .v1, .v2, .v2])
    #expect(s0.ask == "请说。")
  }

  @Test("lab E7: one delay per run, from the list; a client that leaves is logged; `lab use` restarts the list")
  func e7() async throws {
    let h = try LabHarness.make(.e7, delays: [3, 5])
    var waits: [String] = []
    for _ in 0..<3 {
      let s0 = await h.step("", 0)
      waits.append(await h.step(s0.run, 1, "随便").say)
    }
    #expect(waits == ["等了3秒。", "等了5秒。", "等了3秒。"])
    let sig = CancelSignal()
    let s0 = await h.step("", 0)
    async let p = h.step(s0.run, 1, "随便", signal: sig)
    sig.cancel()
    _ = await p
    if case .int? = h.logs.events.last?["client_gave_up_ms"] {} else { Issue.record("client_gave_up_ms is logged") }
    try Lab.writeState(h.file, scenario: .e7, delays: [9], now: Date().timeIntervalSince1970 * 1000 + 1)
    let n0 = await h.step("", 0)
    #expect(await h.step(n0.run, 1, "x").say == "等了9秒。")
  }

  @Test("lab state: bad files fall back to E1 with the default delays")
  func badState() throws {
    let file = try tmpDir().appendingPathComponent("lab.json")
    try Data(#"{"scenario":"E9","delays":[0,"x"]}"#.utf8).write(to: file)
    let st = Lab.readState(file)
    #expect(st.scenario == .e1)
    #expect(st.delays == [8, 12, 16, 20, 25, 30])
    try Data("not json".utf8).write(to: file)
    #expect(Lab.readState(file).scenario == .e1)
    #expect(Lab.readState(file.appendingPathExtension("missing")).delays == Lab.defaultDelays)
  }

  @Test("lab over HTTP: off by default; lab tokens only; JSON every time; never reaches a bot")
  func overHTTP() async throws {
    do {
      let v = try await Voice.start(admit: kindAdmit)
      let off = await RawHTTP.post(port: v.port, path: "/v1/lab", token: "lab-token", ["step": "0"])
      #expect(off.status == 404)
      #expect(off.json["next"] as? String == "end", "without the lab, the lab Shortcut hears why and stops (re-review S3)")
      #expect((off.json["say"] as? String)?.contains("homebot start --lab") == true)
      await v.stop()
    }
    let v = try await Voice.start(admit: kindAdmit, lab: try LabHarness.make(.e1b).svc, maxBodyBytes: 1024)
    let wrong = await RawHTTP.post(port: v.port, path: "/v1/lab", token: "ask-token", ["step": "0"])
    #expect(wrong.status == 401)
    #expect(wrong.json["next"] as? String == "end", "a refusal still ends the Shortcut's loop")
    #expect(await RawHTTP.post(port: v.port, token: "lab-token", ["text": "hi"]).status == 401, "/v1/ask refuses lab tokens")
    let s0 = await RawHTTP.post(port: v.port, path: "/v1/lab", token: "lab-token", ["v": "2", "step": "0", "run": "", "last": "10", "text": ""]).json
    #expect(s0["next"] as? String == "listen")
    // Shortcuts sends Repeat Index as text.
    let s1 = await RawHTTP.post(port: v.port, path: "/v1/lab", token: "lab-token", ["v": "2", "step": "1", "run": s0["run"] as? String ?? "", "last": "10", "text": ""]).json
    #expect(s1["next"] as? String == "listen")
    #expect(v.asked.value.isEmpty, "no bot request")
    // Every refusal and failure still carries a line to speak and ends the loop (review S3).
    func ends(_ r: RawResponse, _ status: Int) {
      #expect(r.status == status)
      #expect(r.json["next"] as? String == "end")
      #expect(((r.json["say"] as? String) ?? "").count > 0)
    }
    ends(await RawHTTP.post(port: v.port, path: "/v1/lab", token: "lab-token", [Any]()), 400)
    ends(await RawHTTP.post(port: v.port, path: "/v1/lab", token: "lab-token", ["text": String(repeating: "x", count: 2000)]), 413)
    ends(await RawHTTP.get(port: v.port, path: "/v1/lab", token: "lab-token"), 405)
    await v.stop()
  }
}
