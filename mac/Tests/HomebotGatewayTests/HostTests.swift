// The gateway host end to end: real stores in a temporary support directory, the fake Grok Bot
// API as the transport, the listener on an ephemeral loopback port, the activity database, the
// owner lock and the control socket. Shortcut-shaped requests only.
import Foundation
import Testing

@testable import HomebotCore
@testable import HomebotGateway
import HomebotTestSupport

/// A short private directory under /tmp (a Unix socket path must stay under 104 bytes).
func shortTmpDir() throws -> URL {
  let u = URL(fileURLWithPath: "/tmp/hb-\(Random.hex(bytes: 4))", isDirectory: true)
  try FileUtil.ensurePrivateDir(u)
  return u
}

let chai = Bot(key: "chai", name: "拆解师", sessionId: "14752726", strictEcho: true)
let kitchen = Bot(key: "kitchen", name: "厨房", sessionId: "555", strictEcho: true)

struct HostHarness {
  let host: GatewayHost
  let fake: FakeGrokBot
  let home: Home
  let port: Int
  let logs: LogSink

  static func start(bots: [Bot] = [chai], settings: SettingsPatch? = nil, home existing: Home? = nil, fake existing2: FakeGrokBot? = nil, lab: Bool = false) async throws -> HostHarness {
    let home = try existing ?? Home(root: try shortTmpDir())
    try home.prepare()
    let fake = existing2 ?? FakeGrokBot()
    if existing == nil {
      let s = try await Stores(home)
      var p = settings ?? SettingsPatch()
      p.answerBudgetMs = p.answerBudgetMs ?? 1500
      p.pollMs = p.pollMs ?? 10
      try await s.config.putSettings(p)
      for b in bots {
        fake.add(b.sessionId, kind: "message", role: "user", text: "old question")
        fake.add(b.sessionId, kind: "send-message", text: "old answer")
        let c = try await Bots.coldSync(fake.client(), sessionId: b.sessionId)
        try await s.lifecycle.add(b, cursor: c.cursor, maxSeq: c.maxSeq)
      }
      try Credentials(keyFile: home.apiKey, userHome: home.root).save(key: FakeGrokBot.key)
    }
    let logs = LogSink()
    let host = GatewayHost(GatewayOptions(home: home, userHome: home.root, port: 0, bind: "127.0.0.1", bdkBaseURL: FakeGrokBot.baseURL, transport: fake, probeUnitMs: 5, lab: lab, labUnit: 0.001, keepAwake: false, traceIdle: .init(maxMs: 0, everyMs: 1000), log: logs.fn))
    let st = try await host.start()
    return HostHarness(host: host, fake: fake, home: home, port: st.port, logs: logs)
  }

  /// Another process's view of the stores (the CLI).
  func stores() async throws -> Stores { try await Stores(home) }

  func issue(_ bots: [Bot], mode: ShortcutMode = .single, label: String = "问拆解师", kind: TokenKind = .ask, replaces: String? = nil) async throws -> (id: String, token: String) {
    let s = try await stores()
    return try await s.lifecycle.issueFor(bots) { b in try await s.tokens.issue(bots: b.map { BotGrant(key: $0.key, sessionId: $0.sessionId) }, label: label, replaces: replaces, siriLang: "zh-CN", kind: kind, mode: mode) }
  }

  func state(_ id: String) async throws -> TokenState? {
    let s = try await stores()
    return await s.tokens.list().first { $0.id == id }?.state
  }

  func post(_ token: String, _ body: [String: Any]) async -> RawResponse { await RawHTTP.post(port: port, token: token, body) }

  func control(_ cmd: [String: Any]) throws -> [String: Any] {
    let out = try ControlClient.call(path: home.controlSocket.path, RawHTTP.json(cmd))
    return (try? JSONSerialization.jsonObject(with: out)) as? [String: Any] ?? [:]
  }

  func stop() async {
    await host.stop()
    try? FileManager.default.removeItem(at: home.root)
  }
}

struct Stores {
  let config: ConfigStore
  let state: StateStore
  let tokens: TokenStore
  var lifecycle: BotLifecycle { BotLifecycle(config: config, state: state, tokens: tokens) }

  init(_ home: Home) async throws {
    config = try await ConfigStore(file: home.config).load()
    state = try await StateStore(file: home.state).load()
    tokens = try await TokenStore(file: home.tokens, artifactsDir: home.shortcuts).load()
  }
}

@Suite("Gateway host", .serialized)
struct HostTests {
  let zh = Messages.of(.zhCN)

  @Test("a Shortcut-shaped question is answered, its answer activates the token, and it leaves one activity record without secrets")
  func shortcutQuestion() async throws {
    let h = try await HostHarness.start()
    let t = try await h.issue([chai])
    #expect(try await h.state(t.id) == .pending)
    h.fake.autoReply(chai.sessionId, text: "现在**三点**。")
    let r = await h.post(t.token, ["text": "几点了"])
    #expect(r.status == 200)
    #expect(r.text == "现在三点。")
    #expect(try await h.state(t.id) == .active, "the first answered request activates (T5)")
    let recs = try h.control(["cmd": "activity"])["records"] as? [[String: Any]] ?? []
    #expect(recs.count == 1)
    #expect(recs.first?["question"] as? String == "几点了")
    #expect(recs.first?["spoken"] as? String == "现在三点。")
    #expect(recs.first?["outcome"] as? String == "answered")
    #expect(recs.first?["botName"] as? String == "拆解师")
    #expect(recs.first?["tokenId"] as? String == t.id)
    await h.host.stop()
    for f in ActivityStore(dir: h.home.activity).files {
      guard let data = FileManager.default.contents(atPath: f.path) else { continue }
      #expect(data.range(of: Data(t.token.utf8)) == nil, "no token in \(f.lastPathComponent)")
      #expect(data.range(of: Data(FakeGrokBot.key.utf8)) == nil, "no key in \(f.lastPathComponent)")
      #expect(data.range(of: Data("hb:".utf8)) == nil, "no echo tag in \(f.lastPathComponent)")
      #expect(data.range(of: Data("Homebot voice".utf8)) == nil, "no envelope in \(f.lastPathComponent)")
    }
    let log = (try? String(contentsOf: h.home.logs.appendingPathComponent("homebot.jsonl"), encoding: .utf8)) ?? ""
    #expect(log.contains("\"event\":\"ask\""))
    #expect(!log.contains("几点了") && !log.contains(t.token) && !log.contains(FakeGrokBot.key), "the diagnostic log holds no text or secrets (A7)")
    try? FileManager.default.removeItem(at: h.home.root)
  }

  @Test("A3: refusals before authentication are counted, not recorded")
  func counted() async throws {
    let h = try await HostHarness.start()
    _ = await h.post("wrong", ["text": "secret question"])
    _ = await RawHTTP.send(port: h.port, headers: ["X-Homebot-Token": "x"], body: Data("[]".utf8))
    let recs = try h.control(["cmd": "activity"])["records"] as? [[String: Any]] ?? []
    #expect(recs.isEmpty)
    let counts = try await h.host.activity.counts()
    #expect(counts.map(\.outcome).sorted() == ["bad-json", "bad-token"])
    await h.stop()
  }

  @Test("one owner per support directory; the lock is released on stop")
  func owner() async throws {
    let h = try await HostHarness.start()
    let second = GatewayHost(GatewayOptions(home: h.home, userHome: h.home.root, port: 0, bind: "127.0.0.1", transport: h.fake, keepAwake: false))
    await #expect(throws: GatewayError.self) { try await second.start() }
    #expect(OwnerLock.isHeld(h.home.gatewayLock))
    await h.host.stop()
    #expect(!OwnerLock.isHeld(h.home.gatewayLock))
    #expect(!FileManager.default.fileExists(atPath: h.home.controlSocket.path), "the socket file is removed")
    let st = try await second.start()
    #expect(st.running)
    await second.stop()
    try? FileManager.default.removeItem(at: h.home.root)
  }

  @Test("control channel: status, activity and Clear go through the owner")
  func control() async throws {
    let h = try await HostHarness.start()
    let t = try await h.issue([chai])
    h.fake.autoReply(chai.sessionId)
    _ = await h.post(t.token, ["text": "几点了"])
    let st = try h.control(["cmd": "status"])
    #expect(st["running"] as? Bool == true)
    #expect(st["port"] as? Int == h.port)
    #expect(st["credential"] as? String == "saved")
    #expect(st["accepted"] as? String == "ok", "Grok Bot accepted the key on the first turn")
    #expect(st["lastOutcome"] as? String == "answered")
    #expect(st["textHistory"] as? Bool == true)
    #expect(FileUtil.mode(h.home.controlSocket) == 0o600)
    #expect(try h.control(["cmd": "clear"])["ok"] as? Bool == true)
    #expect((try h.control(["cmd": "activity"])["records"] as? [Any])?.isEmpty == true)
    #expect(try h.control(["cmd": "nope"])["error"] as? String == "unknown command")
    await h.stop()
    #expect(throws: ControlError.noOwner) { _ = try ControlClient.call(path: h.home.controlSocket.path, Data("{}".utf8)) }
  }

  @Test("the last request comes from the activity store: it survives a restart and Clear empties it")
  func lastRequestAfterRestart() async throws {
    let h = try await HostHarness.start()
    let t = try await h.issue([chai])
    h.fake.autoReply(chai.sessionId)
    _ = await h.post(t.token, ["text": "几点了"])
    let before = await h.host.status()
    #expect(before.lastOutcome == "answered")
    await h.host.stop()
    #expect(await h.host.status().lastAt == nil, "a stopped gateway reports no last request")
    // A new process on the same folder: the voice API's memory is empty, the store is not.
    let again = try await HostHarness.start(home: h.home, fake: h.fake)
    let after = await again.host.status()
    #expect(after.lastOutcome == "answered")
    #expect(after.lastAt == before.lastAt)
    #expect(after.lastAt == (try await again.host.activity.recent(limit: 1)).first?.at)
    #expect(try again.control(["cmd": "clear"])["ok"] as? Bool == true)
    let cleared = await again.host.status()
    #expect(cleared.lastAt == nil && cleared.lastOutcome == nil)
    await again.stop()
  }

  @Test("entry flow over HTTP: the menu and /v1/bots never activate; the choice pins; the first answer activates (T5)")
  func entry() async throws {
    let h = try await HostHarness.start(bots: [chai, kitchen])
    let t = try await h.issue([chai, kitchen], mode: .entry, label: "家庭助手")
    let list = await RawHTTP.get(port: h.port, path: "/v1/bots", token: t.token)
    #expect(list.status == 200)
    #expect(list.text == #"{"bots":[{"key":"chai","name":"拆解师"},{"key":"kitchen","name":"厨房"}]}"#)
    #expect(await RawHTTP.get(port: h.port, path: "/v1/bots", token: "nope").status == 401)
    let s0 = await h.post(t.token, ["v": "2", "step": "0", "run": "", "last": "10", "text": "", "prompt": ""]).json
    #expect((s0["say"] as? String)?.contains("拆解师") == true)
    #expect((s0["say"] as? String)?.contains("厨房") == true)
    #expect(s0["next"] as? String == "listen")
    #expect(try await h.state(t.id) == .pending, "the menu does not activate")
    let run = s0["run"] as? String ?? ""
    let s1 = await h.post(t.token, ["v": "2", "step": "1", "run": run, "last": "10", "text": "二"]).json
    #expect((s1["say"] as? String)?.hasPrefix("厨房") == true, "the choice is spoken back")
    #expect(try await h.state(t.id) == .pending, "the pin marks the token used; it is not active before an answer")
    h.fake.autoReply(kitchen.sessionId, text: "冰箱里有牛奶。")
    let s2 = await h.post(t.token, ["v": "2", "step": "2", "run": run, "last": "10", "text": "冰箱里有什么"]).json
    #expect(s2["say"] as? String == "冰箱里有牛奶。")
    #expect(try await h.state(t.id) == .active, "the first answer activates")
    #expect(h.fake.posts.map(\.sid) == [kitchen.sessionId], "only the chosen bot got a message")
    let recs = (try h.control(["cmd": "activity"])["records"] as? [[String: Any]] ?? []).reversed()
    #expect(recs.map { $0["outcome"] as? String } == ["chosen", "answered"])
    #expect(recs.first?["question"] == nil, "a choosing step keeps no question text (A1)")
    let runs = recs.map { $0["run"] as? Int }
    #expect(runs.first! != nil && runs.allSatisfy { $0 == runs.first! }, "every record of the run carries its local number (\(runs))")
    #expect(recs.allSatisfy { $0["mode"] as? String == "entry" })
    await h.stop()
  }

  // DECISIONS item 27: a replacement takes over only after its first answered request.
  func ask(_ h: HostHarness, _ token: String) async -> RawResponse { await h.post(token, ["bot": "chai", "text": "几点了"]) }

  @Test("replacement (v1): refused, timed-out, failed and busy requests take nothing over; the old one answers in between; the first answer does")
  func replacementTakeover() async throws {
    let h = try await HostHarness.start(settings: { var p = SettingsPatch(); p.answerBudgetMs = 500; return p }())
    let old = try await h.issue([chai], label: "v1")
    h.fake.autoReply(chai.sessionId, text: "旧的回答。")
    #expect(await ask(h, old.token).text == "旧的回答。")
    #expect(try await h.state(old.id) == .active)
    let new = try await h.issue([chai], label: "v2", replaces: old.id)
    func unchanged(_ why: String) async throws {
      #expect(try await h.state(new.id) == .pending, "\(why): the new one is not active")
      #expect(try await h.state(old.id) == .active, "\(why): the old one is not retired")
      h.fake.autoReply(chai.sessionId, text: "旧的还在。")
      #expect(await ask(h, old.token).text == "旧的还在。", "\(why): the old Shortcut still answers")
    }
    h.fake.autoReply(chai.sessionId, text: "没有标记", echo: false)
    #expect(await ask(h, new.token).text == zh.refused)
    try await unchanged("refused")
    h.fake.setOnMessage { _, _ in } // no reply at all
    #expect(await ask(h, new.token).text == zh.noReplyInTime("拆解师"))
    try await unchanged("timeout")
    h.fake.intercept = { m, what, _, _ in m == "POST" && what == "messages" ? .status(400) : nil }
    #expect(await ask(h, new.token).text == zh.upstreamDown)
    h.fake.intercept = nil
    try await unchanged("error")
    h.fake.setIdle(chai.sessionId, false)
    #expect(await ask(h, new.token).text == zh.busy("拆解师"))
    h.fake.setIdle(chai.sessionId, true)
    try await unchanged("busy")
    h.fake.autoReply(chai.sessionId, text: "新的回答。")
    #expect(await ask(h, new.token).text == "新的回答。")
    #expect(try await h.state(new.id) == .active)
    #expect(try await h.state(old.id) == .retired)
    #expect(await ask(h, old.token).status == 401, "the old Shortcut stops only now")
    await h.stop()
  }

  @Test("replacement (conversation): a refused first turn takes nothing over; the first answered turn does")
  func replacementConversation() async throws {
    let h = try await HostHarness.start()
    let old = try await h.issue([chai], mode: .conversation, label: "v1")
    h.fake.autoReply(chai.sessionId, text: "好的。")
    func run(_ token: String) async -> [String: Any] {
      let s0 = await h.post(token, ["v": "2", "bot": "chai", "step": "0", "run": "", "last": "10", "text": "", "prompt": "问吧"]).json
      return await h.post(token, ["v": "2", "bot": "chai", "step": "1", "run": s0["run"] as? String ?? "", "last": "10", "text": "几点了"]).json
    }
    #expect(await run(old.token)["say"] as? String == "好的。")
    let new = try await h.issue([chai], mode: .conversation, label: "v2", replaces: old.id)
    h.fake.autoReply(chai.sessionId, text: "x", echo: false)
    let refused = await run(new.token)
    #expect(refused["say"] as? String == zh.refused && refused["next"] as? String == "end")
    #expect(try await h.state(new.id) == .pending)
    #expect(try await h.state(old.id) == .active)
    h.fake.autoReply(chai.sessionId, text: "好的。")
    #expect(await run(old.token)["say"] as? String == "好的。", "the old Shortcut still answers")
    let ok = await run(new.token)
    #expect(ok["say"] as? String == "好的。" && ok["next"] as? String == "listen")
    #expect(try await h.state(new.id) == .active)
    #expect(try await h.state(old.id) == .retired)
    await h.stop()
  }

  @Test("replacement (entry): the pin takes nothing over; a refused turn neither; the first answered turn does")
  func replacementEntry() async throws {
    let h = try await HostHarness.start(bots: [chai, kitchen])
    let old = try await h.issue([chai, kitchen], mode: .entry, label: "家庭助手")
    _ = try await (await h.stores()).tokens.takeOver(old.id) // installed and answering
    let new = try await h.issue([chai, kitchen], mode: .entry, label: "家庭助手", replaces: old.id)
    func pinned() async -> String {
      let s0 = await h.post(new.token, ["v": "2", "step": "0", "run": "", "last": "10", "text": "", "prompt": ""]).json
      let run = s0["run"] as? String ?? ""
      _ = await h.post(new.token, ["v": "2", "step": "1", "run": run, "last": "10", "text": "一"])
      return run
    }
    h.fake.autoReply(chai.sessionId, text: "x", echo: false)
    let r1 = await pinned()
    #expect(try await h.state(new.id) == .pending, "the pin alone takes nothing over")
    _ = await h.post(new.token, ["v": "2", "step": "2", "run": r1, "last": "10", "text": "几点了"])
    #expect(try await h.state(new.id) == .pending, "a refused turn takes nothing over")
    #expect(try await h.state(old.id) == .active, "a refused turn takes nothing over")
    h.fake.autoReply(chai.sessionId, text: "三点。")
    let r2 = await pinned()
    let a = await h.post(new.token, ["v": "2", "step": "2", "run": r2, "last": "10", "text": "几点了"]).json
    #expect(a["say"] as? String == "三点。")
    #expect(try await h.state(new.id) == .active)
    #expect(try await h.state(old.id) == .retired)
    await h.stop()
  }

  @Test("a client that leaves during a conversation step cancels the step's work at once")
  func cancelledStep() async throws {
    let h = try await HostHarness.start(settings: { var p = SettingsPatch(); p.answerBudgetMs = 8000; return p }())
    let t = try await h.issue([chai], mode: .conversation)
    let s0 = await h.post(t.token, ["v": "2", "bot": "chai", "step": "0", "run": "", "last": "10", "text": "", "prompt": "问吧"]).json
    h.fake.autoReply(chai.sessionId, ms: 5000, text: "很晚的回答")
    let t0 = Date()
    let r = await RawHTTP.send(port: h.port, headers: ["X-Homebot-Token": t.token, "Content-Type": "application/json"], body: RawHTTP.json(["v": "2", "bot": "chai", "step": "1", "run": s0["run"] as? String ?? "", "last": "10", "text": "慢问题"]), abortAfterMs: 300)
    #expect(r.status == 0)
    #expect(await eventually(ms: 3000) { h.logs.first("ask") != nil }, "the turn finished")
    #expect(Date().timeIntervalSince(t0) < 3, "well before the 5 s reply or the 8 s budget")
    let outcome: String = { if case .string(let s)? = h.logs.first("ask")?["outcome"] { return s }; return "" }()
    #expect(outcome.contains("client") || outcome.contains("disconnect"), "outcome: \(outcome)")
    await h.stop()
  }

  @Test("pipelined requests: a client that leaves still cancels the older request (guard for Codex S2 review 3, not reproduced)")
  func pipelinedCancel() async throws {
    let h = try await HostHarness.start(settings: { var p = SettingsPatch(); p.answerBudgetMs = 8000; return p }())
    let t = try await h.issue([chai])
    h.fake.autoReply(chai.sessionId, ms: 5000, text: "很晚的回答")
    let body = String(decoding: RawHTTP.json(["bot": "chai", "text": "慢问题", "v": "1"]), as: UTF8.self)
    let a = "POST /v1/ask HTTP/1.1\r\nHost: x\r\nX-Homebot-Token: \(t.token)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    let b = "GET /v1/health HTTP/1.1\r\nHost: x\r\n\r\n"
    let t0 = Date()
    await RawHTTP.writeThenClose(port: h.port, Data((a + b).utf8), closeAfterMs: 300)
    #expect(await eventually(ms: 3000) { h.logs.first("ask") != nil }, "the older request's turn finished")
    #expect(Date().timeIntervalSince(t0) < 3, "well before the 5 s reply")
    await h.stop()
  }

  @Test("T3: a token revoked while the bot answers gets no answer (Codex S2 review 1)")
  func revokedWhileAnswering() async throws {
    let h = try await HostHarness.start()
    let t = try await h.issue([chai])
    h.fake.autoReply(chai.sessionId, ms: 400, text: "不该听到的回答")
    async let r = h.post(t.token, ["bot": "chai", "text": "几点了", "v": "1"])
    try await Task.sleep(nanoseconds: 150_000_000)
    #expect(try await h.stores().tokens.revoke(t.id))
    let res = await r
    #expect(res.text == Messages.of(.zhCN).botNotConfigured, "\(res.text)")
    await h.stop()
  }

  @Test("an entry token for one bot stays in the entry flow: its bot is spoken and pinned (Codex S2 review 10)")
  func oneBotEntry() async throws {
    let h = try await HostHarness.start()
    let t = try await h.issue([chai], mode: .entry, label: "家庭助手")
    let s0 = await h.post(t.token, ["v": "2", "step": "0", "run": "", "last": "10", "text": "", "prompt": "问吧"]).json
    #expect((s0["say"] as? String)?.contains(chai.name) == true, "\(s0)")
    #expect(try await h.stores().tokens.list().first { $0.id == t.id }?.usedAt != nil, "the pin marks the token used (an answer activates it)")
    await h.stop()
  }

  @Test("a v1 request with a one-bot entry token is a question, and it activates (Codex S4 review 5)")
  func entryTokenV1() async throws {
    let h = try await HostHarness.start()
    let t = try await h.issue([chai], mode: .entry, label: "家庭助手")
    h.fake.autoReply(chai.sessionId, text: "现在三点。", reportsBusy: false)
    #expect(await h.post(t.token, ["text": "几点了", "v": "1"]).text == "现在三点。")
    #expect(try await h.state(t.id) == .active)
    await h.stop()
  }

  @Test("a menu entry whose bot was removed and re-added activates and retires nothing (Codex S4 review 3)")
  func stalePin() async throws {
    let h = try await HostHarness.start(bots: [chai, kitchen])
    let s = try await h.stores()
    let old = try await h.issue([chai], mode: .single, label: "问拆解师")
    h.fake.autoReply(chai.sessionId, text: "好。", reportsBusy: false)
    _ = await h.post(old.token, ["text": "在吗", "v": "1"]) // its answer activates the old one
    #expect(try await h.state(old.id) == .active)
    let new = try await s.lifecycle.issueFor([chai, kitchen]) { b in
      try await s.tokens.issue(bots: b.map { BotGrant(key: $0.key, sessionId: $0.sessionId) }, label: "家庭助手", replaces: old.id, siriLang: "zh-CN", mode: .entry)
    }
    let s0 = await h.post(new.token, ["v": "2", "step": "0", "run": "", "last": "10", "text": ""]).json
    let run = s0["run"] as? String ?? ""
    // While the menu is open, 拆解师 is removed and re-added with another conversation, and granted again.
    _ = try await s.lifecycle.remove(chai.key)
    let chai2 = Bot(key: chai.key, name: chai.name, sessionId: "999", strictEcho: true)
    h.fake.add("999", kind: "send-message", text: "old")
    try await s.lifecycle.add(chai2, cursor: "1", maxSeq: "1")
    try await s.lifecycle.setBots(new.id, [chai2, kitchen])
    let s1 = await h.post(new.token, ["v": "2", "step": "1", "run": run, "last": "10", "text": "一"]).json
    #expect((s1["say"] as? String)?.hasPrefix("问哪个机器人？") == true, "the menu again, from the live list: \(s1)")
    #expect(try await h.state(new.id) == .pending, "the stale choice activated nothing")
    await h.stop()
  }

  @Test("a running gateway removes Shortcut files once they are 24 h old (M2 S2)")
  func artifactSweep() async throws {
    let home = try Home(root: try shortTmpDir())
    try home.prepare()
    let s = try await Stores(home)
    let (id, _) = try await s.tokens.issue(bots: [BotGrant(key: "chai", sessionId: "1")], label: "x")
    let file = try s.tokens.artifactPath(id, ext: "shortcut")
    let host = GatewayHost(GatewayOptions(home: home, userHome: home.root, port: 0, bind: "127.0.0.1", transport: FakeGrokBot(), cleanupMs: 20, keepAwake: false))
    try await host.start()
    // Written after the start-up sweep, so only the timer can remove it.
    try FileUtil.writePrivateFile(file, "x")
    let fresh = try s.tokens.artifactPath(id, ext: "token")
    try FileUtil.writePrivateFile(fresh, "y")
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-25 * 3600)], ofItemAtPath: file.path)
    #expect(await eventually(ms: 2000) { !FileManager.default.fileExists(atPath: file.path) })
    #expect(FileManager.default.fileExists(atPath: fresh.path), "a young file of a pending token stays")
    await host.stop()
    try? FileManager.default.removeItem(at: home.root)
  }

  @Test("the Grok Bot API base is Cursor's or loopback only")
  func allowedBase() {
    #expect(GatewayOptions.isAllowedBase(HTTPBdkClient.defaultBaseURL))
    #expect(GatewayOptions.isAllowedBase("http://127.0.0.1:4010/v0/grokbot/sessions"))
    #expect(!GatewayOptions.isAllowedBase("http://192.168.1.2:4010/v0/grokbot/sessions"))
    #expect(!GatewayOptions.isAllowedBase("https://evil.example/v0/grokbot/sessions"))
    #expect(!GatewayOptions.isAllowedBase("http://user@127.0.0.1/x"))
  }
}
