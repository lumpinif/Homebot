// Ported from test/voice.test.ts and the HTTP parts of test/conversation.test.ts: the voice API
// over a real listener on an ephemeral loopback port, with fake token checks and a fake ask.
import Foundation
import Testing

@testable import HomebotCore
@testable import HomebotGateway
import HomebotTestSupport

let chaiGrant = BotGrant(key: "chai", sessionId: "1")
func record(siriLang: String? = nil, kind: TokenKind? = nil, bots: [BotGrant] = [chaiGrant], mode: ShortcutMode? = nil) -> TokenRecord {
  TokenRecord(id: "aaaaaaaaaaaa", hash: "", bots: bots, label: "test", state: .active, createdAt: 0, siriLang: siriLang, kind: kind, mode: mode)
}

typealias Admit = @Sendable (String, String?, TokenKind, Bool) async throws -> VerifyResult

/// Like TokenStore.verify: "<kind>-token" works at its kind's endpoints; a named bot must be chai.
let kindAdmit: Admit = { token, bot, kind, _ in
  guard token == "\(kind.rawValue)-token" else { return .invalid }
  if let bot, bot != "chai" { return .forbidden }
  return .ok(record(siriLang: "zh-CN", kind: kind == .ask ? nil : kind), bot: chaiGrant)
}

struct Voice {
  let server: HTTPServer
  let port: Int
  let asked: Box<[AskRequest]>
  let logs: LogSink
  let api: VoiceAPI

  static func start(admit: @escaping Admit = { _, _, _, _ in .ok(record(), bot: chaiGrant) }, ask: AskFn? = nil, probeWait: Bool = false, rateLimit: Int = 100, lab: LabService? = nil, downloads: Downloads? = nil, activity: ActivityStore? = nil, bots: [Bot] = [], maxBodyBytes: Int = 16 * 1024, conversation: ConversationService? = nil, noteAnswer: (@Sendable (String, Bool) async throws -> Void)? = nil) async throws -> Voice {
    let asked = Box<[AskRequest]>([])
    let logs = LogSink()
    let fn: AskFn = ask ?? { q in
      asked.mutate { $0.append(q) }
      return AskResult(text: "got:\(q.text)", outcome: "answered")
    }
    let counting: AskFn = { q in
      if ask != nil { asked.mutate { $0.append(q) } }
      return try await fn(q)
    }
    var settings = Settings()
    settings.rateLimitPerMin = rateLimit
    let s = settings
    let api = VoiceAPI(VoiceDeps(admit: admit, noteAnswer: noteAnswer, ask: counting, conversation: conversation, settings: { s }, bots: { bots }, activity: activity, log: logs.fn, probeWait: probeWait, probeUnitMs: 5, downloads: downloads, lab: lab, maxBodyBytes: maxBodyBytes))
    let server = HTTPServer(host: "127.0.0.1")
    let port = try await server.start(port: 0, api: api)
    return Voice(server: server, port: port, asked: asked, logs: logs, api: api)
  }

  func health() async -> Int { await RawHTTP.get(port: port, path: "/v1/health").status }
  func stop() async { await server.stop() }
}

@Suite("Voice API over HTTP")
struct VoiceTests {
  @Test("B2: an interrupted upload neither crashes the gateway nor reaches the bot")
  func interruptedUpload() async throws {
    let v = try await Voice.start()
    _ = await RawHTTP.send(port: v.port, headers: ["X-Homebot-Token": "t"], body: Data(#"{"text":"hal"#.utf8), contentLength: 500, dropAfterSend: true)
    await sleepMs(50)
    #expect(await v.health() == 200, "gateway still serving")
    #expect(v.asked.value.isEmpty)
    await v.stop()
  }

  @Test("B2: disconnect during slow token activation -> AskService is never called")
  func disconnectDuringActivation() async throws {
    let v = try await Voice.start(admit: { _, _, _, _ in
      await sleepMs(150)
      return .ok(record(), bot: chaiGrant)
    })
    _ = await RawHTTP.send(port: v.port, headers: ["X-Homebot-Token": "t"], body: Data(#"{"text":"hello"}"#.utf8), dropAfterSend: true)
    await sleepMs(300)
    #expect(v.asked.value.isEmpty)
    #expect(await v.health() == 200)
    await v.stop()
  }

  @Test("a client that leaves while the bot answers fires the request's signal")
  func disconnectDuringAsk() async throws {
    let fired = Box(false)
    let v = try await Voice.start(ask: { q in
      let early = await q.signal?.sleep(ms: 5000) == false
      fired.value = early && q.signal?.isCancelled == true
      return AskResult(text: "late", outcome: "no-reply:client-gone")
    })
    let r = await RawHTTP.send(port: v.port, headers: ["X-Homebot-Token": "t"], body: Data(#"{"text":"slow"}"#.utf8), abortAfterMs: 100)
    #expect(r.status == 0, "the client gave up before an answer")
    #expect(await eventually(ms: 2000) { fired.value }, "the signal fired well before the 5 s wait ended")
    await v.stop()
  }

  @Test("B2: a failing token write returns 500 and the gateway survives")
  func failingTokenWrite() async throws {
    struct Synthetic: Error, CustomStringConvertible { var description: String { "EACCES: synthetic write failure /secret/path" } }
    let v = try await Voice.start(admit: { _, _, _, _ in throw Synthetic() })
    let r = await RawHTTP.post(port: v.port, ["text": "hi"])
    #expect(r.status == 500)
    #expect(r.text == "Homebot ran into an error. Please try again later.")
    #expect(v.asked.value.isEmpty)
    #expect(await v.health() == 200)
    #expect(!v.logs.json.contains("/secret/path"), "error details are not logged")
    await v.stop()
  }

  @Test("probe-wait: off by default; when on, cycles delays, speaks in the token's language, logs give-ups")
  func probeWait() async throws {
    do {
      let v = try await Voice.start()
      #expect(await RawHTTP.get(port: v.port, path: "/v1/probe-wait", token: "t").status == 404)
      await v.stop()
    }
    let v = try await Voice.start(admit: { t, _, kind, _ in t == "t" && kind == .probe ? .ok(record(siriLang: "zh-CN", kind: .probe), bot: chaiGrant) : .invalid }, probeWait: true)
    #expect(await RawHTTP.get(port: v.port, path: "/v1/probe-wait", token: "bad").status == 401)
    #expect(await RawHTTP.get(port: v.port, path: "/v1/probe-wait", token: "t").text == "等了5秒，收到。")
    #expect(await RawHTTP.get(port: v.port, path: "/v1/probe-wait", token: "t").text == "等了10秒，收到。")
    let gaveUp = await RawHTTP.get(port: v.port, path: "/v1/probe-wait", token: "t", abortAfterMs: 20) // 15 s step (75 ms here)
    #expect(gaveUp.status == 0)
    #expect(await eventually { v.logs.events.filter { $0["event"] == "probe-end" }.count == 3 })
    let ends = v.logs.events.filter { $0["event"] == "probe-end" }.map { [$0["s"], $0["delivered"]] }
    #expect(ends == [[.int(5), .bool(true)], [.int(10), .bool(true)], [.int(15), .bool(false)]])
    #expect(v.asked.value.isEmpty, "the probe never talks to a bot")
    #expect(await RawHTTP.get(port: v.port, path: "/v1/probe-wait", token: "ask-token").status == 401, "a voice token is refused")
    await v.stop()
  }

  @Test("TS review S1: a body that is not a JSON object is 400 before authentication")
  func notAnObject() async throws {
    let verified = Box(0)
    let v = try await Voice.start(admit: { _, _, _, _ in
      verified.mutate { $0 += 1 }
      return .ok(record(), bot: chaiGrant)
    })
    for body in ["[]", #"[{"text":"hi"}]"#, "null", #""hi""#, "5", "true", "{", "\u{FF}"] {
      let r = await RawHTTP.send(port: v.port, headers: ["X-Homebot-Token": "t"], body: Data(body.utf8))
      #expect(r.status == 400, "\(body)")
      #expect(r.text == #"{"error":"bad json"}"#, "\(body)")
    }
    #expect(verified.value == 0, "no token was checked, so none was activated or retired")
    #expect(v.asked.value.isEmpty)
    let ok = await RawHTTP.post(port: v.port, ["text": "hi"])
    #expect(ok.text == "got:hi", "an object body still works")
    #expect(verified.value > 0, "the object body was authenticated")
    let empty = await RawHTTP.send(port: v.port, headers: ["X-Homebot-Token": "t"], body: Data())
    #expect(empty.status == 200, "an empty body is {} (as in TypeScript)")
    await v.stop()
  }

  @Test("S1: UTF-8 characters split across chunks arrive intact")
  func utf8Chunks() async throws {
    let v = try await Voice.start()
    let body = RawHTTP.json(["text": "中文 😀 ok"])
    let b = [UInt8](body)
    let zhong = [UInt8]("中".utf8), emoji = [UInt8]("😀".utf8)
    func index(of n: [UInt8]) -> Int { (0...(b.count - n.count)).first { Array(b[$0..<$0 + n.count]) == n }! }
    let cut1 = index(of: zhong) + 1, cut2 = index(of: emoji) + 2
    let r = await RawHTTP.send(port: v.port, headers: ["X-Homebot-Token": "t"], parts: [Data(b[0..<cut1]), Data(b[cut1..<cut2]), Data(b[cut2...])])
    #expect(v.asked.value.first?.text == "中文 😀 ok")
    #expect(r.text == "got:中文 😀 ok")
    await v.stop()
  }

  @Test("body limit: 413 with Connection: close, before the token is checked; JSON 404/405; plain-text replies")
  func limitsAndStatus() async throws {
    let verified = Box(0)
    let v = try await Voice.start(admit: { _, _, _, _ in
      verified.mutate { $0 += 1 }
      return .ok(record(), bot: chaiGrant)
    }, maxBodyBytes: 1024)
    let big = await RawHTTP.send(port: v.port, headers: ["X-Homebot-Token": "t"], body: Data(String(repeating: "x", count: 4000).utf8))
    #expect(big.status == 413)
    #expect(big.headers["connection"]?.lowercased() == "close")
    #expect(big.text == "That question is too long. Please keep it short.")
    #expect(verified.value == 0)
    let nf = await RawHTTP.get(port: v.port, path: "/nope")
    #expect(nf.status == 404)
    #expect(nf.text == #"{"error":"not found"}"#)
    let na = await RawHTTP.get(port: v.port, path: "/v1/ask")
    #expect(na.status == 405)
    #expect(na.text == #"{"error":"method not allowed"}"#)
    #expect(await RawHTTP.send(port: v.port, method: "HEAD", path: "/v1/health").status == 404, "health is GET only, as in TypeScript")
    #expect(await RawHTTP.get(port: v.port, path: "/v1/health?x=1").text == #"{"ok":true}"#)
    let ok = await RawHTTP.post(port: v.port, ["text": "hi"])
    #expect(ok.headers["content-type"] == "text/plain; charset=utf-8")
    #expect(ok.headers["cache-control"] == "no-store")
    await v.stop()
  }

  @Test("refusals: 401 bad token, 403 another bot; a v1 request without bot needs a one-bot token")
  func refusals() async throws {
    let two = [chaiGrant, BotGrant(key: "kitchen", sessionId: "2")]
    let v = try await Voice.start(admit: { t, bot, _, _ in
      guard t == "ask-token" else { return .invalid }
      if let bot, bot != "chai" { return .forbidden }
      return .ok(record(bots: two), bot: bot == nil ? nil : chaiGrant)
    })
    let bad = await RawHTTP.post(port: v.port, token: "nope", ["text": "hi"])
    #expect(bad.status == 401)
    #expect(bad.text == "This shortcut no longer works. Please make a new one in Homebot.")
    let other = await RawHTTP.post(port: v.port, token: "ask-token", ["text": "hi", "bot": "x"])
    #expect(other.status == 403)
    let unnamed = await RawHTTP.post(port: v.port, token: "ask-token", ["text": "hi"])
    #expect(unnamed.status == 403, "a multi-bot token must name its bot on v1")
    #expect(v.asked.value.isEmpty)
    let named = await RawHTTP.post(port: v.port, token: "ask-token", ["text": "hi", "bot": "chai"])
    #expect(named.text == "got:hi")
    #expect(v.asked.value.first?.sessionId == "1", "the turn uses the admitted grant's session (T3)")
    #expect(v.asked.value.first?.redact == ["ask-token"], "the token is removed from the answer (A1)")
    await v.stop()
  }

  @Test("conversation over HTTP: JSON for every v2 answer, refusals included; v1 stays plain text")
  func conversationJSON() async throws {
    let n = Box(0)
    let v = try await Voice.start(admit: kindAdmit, ask: { _ in
      n.mutate { $0 += 1 }
      return AskResult(text: "answer \(n.value)", outcome: "answered")
    })
    let bad = await RawHTTP.post(port: v.port, token: "nope", ["v": "2", "bot": "chai", "step": "0"])
    #expect(bad.status == 401)
    #expect(bad.json["next"] as? String == "end")
    let other = await RawHTTP.post(port: v.port, token: "ask-token", ["v": "2", "bot": "kitchen", "step": "0"])
    #expect(other.status == 403)
    #expect(other.json["next"] as? String == "end")
    let s0 = await RawHTTP.post(port: v.port, token: "ask-token", ["v": "2", "bot": "chai", "step": "0", "run": "", "last": "10", "text": "", "prompt": "想问拆解师什么？"]).json
    #expect(s0["say"] as? String == "想问拆解师什么？")
    #expect(s0["next"] as? String == "listen")
    let run = s0["run"] as? String ?? ""
    let s1 = await RawHTTP.post(port: v.port, token: "ask-token", ["v": "2", "bot": "chai", "step": "1", "run": run, "last": "10", "text": "几点了"]).json
    #expect(s1["say"] as? String == "answer 1")
    #expect(s1["next"] as? String == "listen")
    let v1 = await RawHTTP.post(port: v.port, token: "ask-token", ["v": "1", "bot": "chai", "text": "几点了"])
    #expect(v1.headers["content-type"]?.hasPrefix("text/plain") == true)
    #expect(v1.text == "answer 2")
    #expect(v.asked.value.map(\.turn) == [1, nil], "only v2 requests carry a turn")
    await v.stop()
  }

  @Test("conversation over HTTP: only a run's start counts toward the rate limit; failures stay JSON (review S1, S3)")
  func conversationRateLimit() async throws {
    struct Unreadable: Error {}
    do {
      let v = try await Voice.start(admit: { _, _, _, _ in throw Unreadable() })
      let r = await RawHTTP.post(port: v.port, token: nil, ["v": "2", "step": "0"])
      #expect(r.status == 500)
      #expect(r.json["next"] as? String == "end")
      await v.stop()
    }
    let v = try await Voice.start(admit: kindAdmit, ask: { q in AskResult(text: "a:\(q.text)", outcome: "answered") }, rateLimit: 2)
    func post(_ body: [String: Any]) async -> [String: Any] { await RawHTTP.post(port: v.port, token: "ask-token", body).json }
    let s0 = await post(["v": "2", "bot": "chai", "step": "0", "last": "10"])
    for i in 1...4 {
      #expect(await post(["v": "2", "bot": "chai", "step": "\(i)", "run": s0["run"] as? String ?? "", "last": "10", "text": "q\(i)"])["next"] as? String == "listen", "step \(i)")
    }
    _ = await post(["v": "2", "bot": "chai", "step": "0", "last": "10"])
    let limited = await post(["v": "2", "bot": "chai", "step": "0", "last": "10"])
    #expect((limited["say"] as? String)?.contains("太频繁") == true, "new runs are still limited")
    await v.stop()
  }

  @Test("downloads: a link works once; unknown, used and expired links look the same; the id is never logged")
  func downloads() async throws {
    let dir = try tmpDir()
    let file = dir.appendingPathComponent("x.shortcut")
    try Data("SHORTCUT".utf8).write(to: file)
    let t = Box<Double>(1_000_000)
    let dl = Downloads(now: { t.value })
    let v = try await Voice.start(downloads: dl)
    let link = await dl.create(file: file, name: "问拆解师", tokenId: "aaaaaaaaaaaa")
    let r = await RawHTTP.get(port: v.port, path: "/dl/\(link.id)")
    #expect(r.status == 200)
    #expect(r.text == "SHORTCUT")
    #expect(r.headers["content-type"] == "application/octet-stream")
    #expect(r.headers["content-disposition"] == "attachment; filename=\"Homebot.shortcut\"; filename*=UTF-8''%E9%97%AE%E6%8B%86%E8%A7%A3%E5%B8%88.shortcut")
    #expect(r.headers["x-content-type-options"] == "nosniff")
    let again = await RawHTTP.get(port: v.port, path: "/dl/\(link.id)")
    #expect(again.status == 404)
    let expired = await dl.create(file: file, name: "x", tokenId: "b")
    t.value += Downloads.linkTTLms
    let late = await RawHTTP.get(port: v.port, path: "/dl/\(expired.id)")
    #expect(late.status == 404)
    #expect(late.text == again.text)
    #expect(await RawHTTP.get(port: v.port, path: "/dl/not-an-id").text == again.text)
    let dropped = await dl.create(file: file, name: "x", tokenId: "c")
    await dl.dropToken("c")
    #expect(await RawHTTP.get(port: v.port, path: "/dl/\(dropped.id)").status == 404)
    #expect(!v.logs.json.contains(link.id))
    await v.stop()
    do {
      let off = try await Voice.start()
      #expect(await RawHTTP.get(port: off.port, path: "/dl/\(link.id)").status == 404, "no downloads without the store")
      await off.stop()
    }
  }

  @Test("the listener refuses a port in use and frees its port when stopped")
  func portInUse() async throws {
    let v = try await Voice.start()
    let other = HTTPServer(host: "127.0.0.1")
    let api = v.api
    await #expect(throws: GatewayError.self) { _ = try await other.start(port: v.port, api: api) }
    await v.stop()
    #expect(await RawHTTP.get(port: v.port, path: "/v1/health").status == 0, "nothing listens after stop")
    let again = HTTPServer(host: "127.0.0.1")
    #expect(try await again.start(port: v.port, api: api) == v.port, "the port can be bound again")
    await again.stop()
  }

  @Test("JSON bodies match JSON.stringify byte for byte")
  func jsonOut() {
    #expect(JSOut.string("a\"b\\c\n\t\u{1}/é😀") == #""a\"b\\c\n\t\u0001/é😀""#)
    #expect(JSOut.string("\u{2028}") == "\"\u{2028}\"")
    #expect(JSOut.loop(LoopResponse(say: "x", ask: "", mode: .v1, next: .end, run: "")) == #"{"say":"x","ask":"","mode":"v1","next":"end","run":""}"#)
  }
}
