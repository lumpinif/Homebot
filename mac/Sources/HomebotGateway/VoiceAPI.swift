// The LAN voice API (DESIGN §4.1, §11, §18, §19, §20.5, §20.6): /v1/health, /v1/ask, one-time
// /dl/<id> Shortcut downloads, /v1/bots, and, only when enabled for a device session,
// /v1/probe-wait and /v1/lab. JSON requests; /v1/ask answers plain text that Siri reads aloud,
// except v2 (conversation) requests, which get JSON in every case. Ported from
// src/server/voice.ts; the HTTP framing (body cap, disconnects) lives in HTTPServer.
import Foundation
import HomebotCore

public struct VoiceRequest: Sendable {
  public var method: String
  /// The request target as sent (query included).
  public var target: String
  /// The first `X-Homebot-Token` header, or "".
  public var token: String
  /// Reads the body; nil when it is longer than `max` bytes (the rest is not read).
  public var readBody: @Sendable (_ max: Int) async throws -> Data?
  /// Fired when the client disconnects.
  public var signal: CancelSignal
  /// The request came from this Mac itself (a loopback address, or the Mac's own address).
  public var here: Bool

  public init(method: String, target: String, token: String = "", signal: CancelSignal = CancelSignal(), here: Bool = false, readBody: @escaping @Sendable (Int) async throws -> Data? = { _ in Data() }) {
    self.here = here
    self.method = method
    self.target = target
    self.token = token
    self.signal = signal
    self.readBody = readBody
  }
}

public struct VoiceResponse: Sendable, Equatable {
  public var status: Int
  public var headers: [String: String]
  public var body: Data
  /// Close the connection after this response (a body over the limit is not read further).
  public var close = false
  /// The client already left: nothing is sent.
  public var dropped = false

  public var text: String { String(decoding: body, as: UTF8.self) }

  static func text(_ status: Int, _ s: String) -> VoiceResponse {
    VoiceResponse(status: status, headers: ["content-type": "text/plain; charset=utf-8", "cache-control": "no-store"], body: Data(s.utf8))
  }

  static func json(_ status: Int, _ s: String) -> VoiceResponse {
    VoiceResponse(status: status, headers: ["content-type": "application/json; charset=utf-8", "cache-control": "no-store"], body: Data(s.utf8))
  }

  static let gone = VoiceResponse(status: 499, headers: [:], body: Data(), dropped: true)
}

/// A request body field, as JSON gave it.
enum JValue: Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case other

  var string: String? {
    if case .string(let s) = self { return s }
    return nil
  }
}

public struct VoiceDeps: Sendable {
  /// T3: verify, admit and (when `use`) mark a pending token used, in one locked step
  /// (BotLifecycle.admit). Never activates or retires anything.
  public var admit: @Sendable (_ token: String, _ bot: String?, _ kind: TokenKind, _ use: Bool) async throws -> VerifyResult
  public var ask: AskFn
  /// The entry flow's pin (T3): admit and mark used exactly this (key, session) grant in one
  /// locked step, refusing when the bot's grant has another session now.
  /// Nil (tests): an authenticate-only check, then a marking admit.
  public var pin: (@Sendable (_ token: String, _ grant: BotGrant) async throws -> VerifyResult)?
  /// T5 takeover (BotLifecycle.takeOver): called once a request of the token ended `answered`,
  /// with the bot that answered (nil for probe and lab tokens) and a check, made under the lock,
  /// that the client is still there. Nil (tests with a stub admit): nothing to take over.
  public var takeOver: (@Sendable (_ tokenId: String, _ bot: String?, _ stillThere: @Sendable () -> Bool) async throws -> Bool)?
  /// Records that a voice token's answer was spoken, and whether on this Mac (TokenStore.noteAnswer).
  public var noteAnswer: (@Sendable (_ tokenId: String, _ here: Bool) async throws -> Void)?
  public var conversation: ConversationService
  public var settings: @Sendable () async -> Settings
  /// The configured bots now (names for the entry flow, the bot list and activity).
  public var bots: @Sendable () async -> [Bot]
  /// The API key in use, removed from stored question text (A1); nil when none.
  public var apiKey: @Sendable () async -> String?
  public var activity: ActivityStore?
  public var log: LogFn
  public var now: @Sendable () -> Double
  public var probeWait: Bool
  public var probeUnitMs: Int
  public var downloads: Downloads?
  /// The device-experiment handler; /v1/lab works only when this is set.
  public var lab: LabService?
  public var maxBodyBytes: Int

  public init(admit: @escaping @Sendable (String, String?, TokenKind, Bool) async throws -> VerifyResult, pin: (@Sendable (String, BotGrant) async throws -> VerifyResult)? = nil, takeOver: (@Sendable (String, String?, @Sendable () -> Bool) async throws -> Bool)? = nil, noteAnswer: (@Sendable (String, Bool) async throws -> Void)? = nil, ask: @escaping AskFn, conversation: ConversationService? = nil, settings: @escaping @Sendable () async -> Settings = { Settings() }, bots: @escaping @Sendable () async -> [Bot] = { [] }, apiKey: @escaping @Sendable () async -> String? = { nil }, activity: ActivityStore? = nil, log: @escaping LogFn = { _ in }, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }, probeWait: Bool = false, probeUnitMs: Int = 1000, downloads: Downloads? = nil, lab: LabService? = nil, maxBodyBytes: Int = 16 * 1024) {
    self.admit = admit
    self.pin = pin
    self.takeOver = takeOver
    self.noteAnswer = noteAnswer
    self.ask = ask
    self.conversation = conversation ?? ConversationService(ask: ask, log: log)
    self.settings = settings
    self.bots = bots
    self.apiKey = apiKey
    self.activity = activity
    self.log = log
    self.now = now
    self.probeWait = probeWait
    self.probeUnitMs = probeUnitMs
    self.downloads = downloads
    self.lab = lab
    self.maxBodyBytes = maxBodyBytes
  }
}

public actor VoiceAPI {
  let d: VoiceDeps
  /// token id -> request times in the last minute
  var recent: [String: [Double]] = [:]
  var probeIdx = 0
  /// Wire run id -> local run number (A1: activity never keeps wire run ids).
  var runNumbers: [String: Int] = [:]
  var runOrder: [String] = []
  var nextRun = 0

  public init(_ deps: VoiceDeps) { d = deps }

  public func handle(_ req: VoiceRequest) async -> VoiceResponse {
    do {
      return try await route(req)
    } catch {
      d.log(["event": "request-error", "error": .string(Log.errorName(error))])
      return .text(500, Messages.of(nil).internalError)
    }
  }

  func route(_ req: VoiceRequest) async throws -> VoiceResponse {
    let path = String(req.target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "/")
    if req.method == "GET" && path == "/v1/health" { return .json(200, #"{"ok":true}"#) }
    if d.probeWait && req.method == "GET" && path == "/v1/probe-wait" { return try await probe(req) }
    if d.downloads != nil && req.method == "GET" && path.hasPrefix("/dl/") { return await download(String(path.dropFirst(4))) }
    if path == "/v1/lab" { return await labStep(req) }
    if path == "/v1/bots" { return await botList(req) }
    if path != "/v1/ask" { return .json(404, #"{"error":"not found"}"#) }
    if req.method != "POST" { return .json(405, #"{"error":"method not allowed"}"#) }
    switch try await readBody(req) {
    case .tooLong:
      await d.activity?.count(endpoint: "/v1/ask", outcome: "too-long")
      var r = VoiceResponse.text(413, Messages.of(nil).tooLong)
      r.close = true
      return r
    case .bad:
      await d.activity?.count(endpoint: "/v1/ask", outcome: "bad-json")
      return .json(400, #"{"error":"bad json"}"#)
    case .object(let body):
      return try await ask(req, body)
    }
  }

  enum Body { case object([String: JValue]), tooLong, bad }

  /// The JSON object body, or why there is none; the caller answers in its own format. Only a
  /// JSON object is a request: anything else (arrays included) is refused before the token is
  /// checked, so a malformed body never marks or retires a token (TS review S1).
  func readBody(_ req: VoiceRequest) async throws -> Body {
    guard let data = try await req.readBody(d.maxBodyBytes) else { return .tooLong }
    // Decoded once, as UTF-8 with replacement like Node's Buffer.toString (chunks may split a char).
    let text = String(decoding: data, as: UTF8.self)
    let json = text.isEmpty ? "{}" : text
    guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) as? [String: Any] else { return .bad }
    var out: [String: JValue] = [:]
    for (k, v) in obj {
      if let n = v as? NSNumber {
        out[k] = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
      } else if let s = v as? String {
        out[k] = .string(s)
      } else {
        out[k] = .other
      }
    }
    return .object(out)
  }

  /// Shortcuts sends numbers as text: a number, or 1–4 digits.
  static func int(_ v: JValue?, _ dflt: Int) -> Int {
    switch v {
    case .number(let n): return Int(exactly: n) ?? (n.isFinite ? -1 : dflt)
    case .string(let s):
      // JavaScript's \d is ASCII only.
      let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
      if t.range(of: "^[0-9]{1,4}$", options: .regularExpression) != nil, let n = Int(t) { return n }
      return dflt
    default: return dflt
    }
  }

  func overLimit(_ id: String) async -> Bool {
    let t = d.now()
    var times = (recent[id] ?? []).filter { t - $0 < 60_000 }
    times.append(t)
    recent[id] = times
    return times.count > (await d.settings()).rateLimitPerMin
  }

  /// A v2 response that ends the run: every refusal and failure is spoken.
  static func endRun(_ status: Int, _ say: String) -> VoiceResponse {
    .json(status, JSOut.loop(LoopResponse(say: say, ask: "", mode: .v1, next: .end, run: "")))
  }

  func runNumber(_ wire: String, start: Bool) -> Int? {
    if let n = runNumbers[wire] { return n }
    guard start, !wire.isEmpty else { return nil }
    nextRun += 1
    runNumbers[wire] = nextRun
    runOrder.append(wire)
    if runOrder.count > 1000 { runNumbers.removeValue(forKey: runOrder.removeFirst()) }
    return nextRun
  }

  func ask(_ req: VoiceRequest, _ body: [String: JValue]) async throws -> VoiceResponse {
    // v1 Shortcuts get plain text, as always; a v2 (conversation) Shortcut gets JSON in every
    // case, so its loop always has a line to speak and a `next` (DESIGN §18.2).
    let v2 = body["v"]?.string == "2"
    let started = d.now()
    func fail(_ status: Int, _ say: String) -> VoiceResponse { v2 ? VoiceAPI.endRun(status, say) : .text(status, say) }
    let requested = body["bot"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    let step = VoiceAPI.int(body["step"], -1)
    let text = body["text"]?.string ?? ""
    do {
      // A request without `bot` marks the token used only once it is known not to be the entry
      // flow: the entry menu never does, its pin does (T5).
      var auth = try await d.admit(req.token, requested, .ask, requested != nil)
      // A v1 request is never the entry flow, whatever the token's mode (T5).
      if case .ok(let rec, let g) = auth, requested == nil, g != nil, rec.mode != .entry || !v2 {
        auth = try await d.admit(req.token, nil, .ask, true)
      }
      guard case .ok(let record, var grant) = auth else {
        // Before authentication the Shortcut's language is unknown: product default (English).
        let forbidden = auth == .forbidden
        d.log(["event": "auth", "outcome": forbidden ? "forbidden" : "invalid"])
        await d.activity?.count(endpoint: "/v1/ask", outcome: forbidden ? "forbidden" : "bad-token")
        return forbidden ? fail(403, Messages.of(.en).forbiddenBot) : fail(401, Messages.of(.en).badToken)
      }
      // A v1 request without `bot` works only for a one-bot token (§20.5, §4.1 step 4); a v2
      // request without one is the entry flow.
      if grant == nil && !v2 {
        d.log(["event": "auth", "outcome": "forbidden"])
        await d.activity?.count(endpoint: "/v1/ask", outcome: "forbidden")
        return fail(403, Messages.of(.en).forbiddenBot)
      }
      // The entry flow follows from the request and the token's mode, never from how many bots
      // the token grants right now (a narrowed entry token stays an entry token).
      let isEntry = v2 && requested == nil && (grant == nil || record.mode == .entry)
      if isEntry { grant = nil }
      let lang = Langs.replyLang(record.siriLang) // the Shortcut's Siri language, bound to its token
      let m = Messages.of(lang)
      let bots = await d.bots()
      let names = Dictionary(bots.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
      let secrets = [req.token] + [await d.apiKey()].compactMap { $0 }
      let settings = await d.settings()
      func note(_ outcome: String, botKey: String?, botName: String?, run: Int? = nil, step: Int? = nil, question: String? = nil, spoken: String?, ask: AskResult? = nil) async {
        guard let activity = d.activity else { return }
        var q = question.map { ProtocolFilter.clean($0.trimmingCharacters(in: .whitespacesAndNewlines), secrets: secrets) }
        var tooLong = false
        let cap = max(0, settings.maxQuestionChars) // a stored negative limit never traps
        if let s = q, s.unicodeScalars.count > cap {
          q = String(String.UnicodeScalarView(s.unicodeScalars.prefix(cap)))
          tooLong = true
        }
        if q?.isEmpty == true { q = nil }
        let t = ask?.timings ?? [:]
        await activity.add(ActivityRecord(
          at: started, durationMs: Int(d.now() - started), baselineMs: t["baseline_ms"], sendMs: t["sent_ms"], replyMs: t["reply_ms"],
          tokenId: record.id, label: record.label, mode: (record.mode ?? .legacy).rawValue, siriLang: record.siriLang,
          botKey: botKey, botName: botName, run: run, step: step, question: q, tooLong: tooLong,
          spoken: spoken.map { ProtocolFilter.clean($0, secrets: secrets) }, outcome: outcome, reason: ask?.reason,
          delivery: ask?.delivery, interim: ask?.interim))
      }
      // A conversation counts once, at its start: its later steps are bounded by the run's step
      // cap, and a retry must still get its cached answer (conversation review S3).
      let counted = !v2 || step == 0
      if counted, await overLimit(record.id) {
        await note("rate-limited", botKey: grant?.key, botName: grant.flatMap { names[$0.key] }, step: v2 ? step : nil, spoken: m.rateLimited)
        return fail(200, m.rateLimited)
      }
      if req.signal.isCancelled { return .gone } // the client left (e.g. during activation): nothing reaches the bot

      if v2 {
        let token = req.token
        let admit = d.admit
        let pinFn = d.pin
        let liveBots = d.bots
        let entry: EntryContext? = grant == nil ? EntryContext(
            choices: {
              guard case .ok(let rec, _)? = try? await admit(token, nil, .ask, false) else { return [] }
              let byKey = Dictionary((await liveBots()).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
              return rec.bots.compactMap { g in byKey[g.key].flatMap { $0.sessionId == g.sessionId ? EntryChoice($0) : nil } }
            },
            pin: { g in
              if let pinFn {
                guard case .ok(_, let pinned)? = try? await pinFn(token, g) else { return false }
                return pinned == g
              }
              guard case .ok(_, let now)? = try? await admit(token, g.key, .ask, false), now == g else { return false }
              guard case .ok(_, let pinned)? = try? await admit(token, g.key, .ask, true) else { return false }
              return pinned == g
            }) : nil
          let wire = body["run"]?.string ?? ""
          let r = await d.conversation.step(ConversationStep(
            run: wire, step: step, last: VoiceAPI.int(body["last"], 0), text: text, prompt: body["prompt"]?.string ?? "",
            botKey: grant?.key, sessionId: grant?.sessionId, tokenId: record.id, lang: lang, signal: req.signal, redact: [req.token], entry: entry))
          // The local run number is given when the run starts, whether or not that step leaves a
          // record (a menu or a prompt does not), so every later record of the run carries it.
          let n = runNumber(r.response.run, start: step == 0)
          if let a = r.activity {
            await note(a.outcome, botKey: a.botKey, botName: a.botName ?? a.botKey.flatMap { names[$0] }, run: n, step: step, question: a.question, spoken: r.response.say, ask: a.ask)
          }
          if req.signal.isCancelled { return .gone }
          // Only an answer the Shortcut is still there to speak takes over.
          if let a = r.activity, a.outcome == "answered" {
            await takeOver(record, bot: a.botKey, signal: req.signal)
            await noteAnswer(record, req)
          }
          return .json(200, JSOut.loop(r.response))
      }

      // `test: true` marks the message "[Homebot test]" for the bot (manual curl checks, M3 L3).
      guard let g = grant else { return fail(403, Messages.of(.en).forbiddenBot) }
      var test = false
      if case .bool(true)? = body["test"] { test = true }
      let token = req.token
      let admit = d.admit
      let r = try await d.ask(AskRequest(botKey: g.key, sessionId: g.sessionId, text: text, lang: lang, test: test, signal: req.signal, redact: [req.token], stillGranted: {
        guard case .ok(_, let now)? = try? await admit(token, g.key, .ask, false) else { return false }
        return now == g
      }))
      await note(r.outcome, botKey: g.key, botName: names[g.key], question: text, spoken: r.text, ask: r)
      if req.signal.isCancelled { return .gone }
      // Only an answer the Shortcut is still there to speak takes over.
      if r.outcome == "answered" {
        await takeOver(record, bot: g.key, signal: req.signal)
        await noteAnswer(record, req)
      }
      return .text(200, r.text)
    } catch {
      // v1 keeps the outer plain-text 500; a v2 loop always gets a line to speak and `next`.
      if !v2 { throw error }
      d.log(["event": "request-error", "error": .string(Log.errorName(error)), "kind": "conversation"])
      return VoiceAPI.endRun(500, Messages.of(.en).internalError)
    }
  }

  /// T5: a pending token takes over (becomes active, retires what it replaces) only after one of
  /// its requests ended with an answer for Siri to speak (DECISIONS item 27). Refused, timed-out,
  /// busy or failed requests leave both Shortcuts as they are. A failed write is logged; the
  /// answer is still returned, and the next answer tries again.
  func takeOver(_ record: TokenRecord, bot: String? = nil, signal: CancelSignal) async {
    guard record.state == .pending, let fn = d.takeOver else { return }
    do {
      if try await fn(record.id, bot, { !signal.isCancelled }) { d.log(["event": "token-takeover", "token": .string(record.id)]) }
    } catch {
      d.log(["event": "token-takeover-error", "error": .string(Log.errorName(error))])
    }
  }

  /// Where a spoken answer went (the Install page's "Answered on this Mac" / "from your iPhone").
  func noteAnswer(_ record: TokenRecord, _ req: VoiceRequest) async {
    guard let fn = d.noteAnswer, !req.signal.isCancelled else { return }
    do {
      try await fn(record.id, req.here)
    } catch {
      d.log(["event": "token-answer-note-error", "error": .string(Log.errorName(error))])
    }
  }

  /// The bots a token may name (DESIGN §20.5 API note). Authenticates only: it never activates
  /// or retires a token (T5). JSON: `{"bots":[{"key","name"}]}` in the set's order, live grants only.
  func botList(_ req: VoiceRequest) async -> VoiceResponse {
    guard req.method == "GET" else { return .json(405, #"{"error":"method not allowed"}"#) }
    do {
      guard case .ok(let record, _) = try await d.admit(req.token, nil, .ask, false) else {
        d.log(["event": "auth", "outcome": "invalid", "kind": "bots"])
        await d.activity?.count(endpoint: "/v1/bots", outcome: "bad-token")
        return .json(401, #"{"error":"bad token"}"#)
      }
      if await overLimit(record.id) { return .json(429, #"{"error":"rate limited"}"#) }
      let byKey = Dictionary((await d.bots()).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
      let live = record.bots.compactMap { g in byKey[g.key].flatMap { $0.sessionId == g.sessionId ? $0 : nil } }
      return .json(200, #"{"bots":["# + live.map { JSOut.object([("key", $0.key), ("name", $0.name)]) }.joined(separator: ",") + "]}")
    } catch {
      d.log(["event": "request-error", "error": .string(Log.errorName(error)), "kind": "bots"])
      return .json(500, #"{"error":"internal"}"#)
    }
  }

  /// One step of the lab Shortcut (DESIGN §19.1). Only lab tokens; nothing reaches a bot. Every
  /// answer, refusals and failures included, is JSON with `say` and `next: "end"` where the run
  /// stops (milestone review S3). Without the lab on, a lab token hears that the lab is off.
  func labStep(_ req: VoiceRequest) async -> VoiceResponse {
    func stop(_ status: Int, _ say: String) -> VoiceResponse { VoiceAPI.endRun(status, say) }
    do {
      if req.method != "POST" { return stop(405, Messages.of(.en).internalError) }
      let body: [String: JValue]
      switch try await readBody(req) {
      case .tooLong:
        var r = stop(413, Messages.of(nil).tooLong)
        r.close = true
        return r
      case .bad: return stop(400, Messages.of(.en).internalError)
      case .object(let b): body = b
      }
      guard case .ok(let record, _) = try await d.admit(req.token, nil, .lab, true) else {
        d.log(["event": "auth", "outcome": "invalid", "kind": "lab"])
        return stop(401, Messages.of(.en).badToken)
      }
      await takeOver(record, signal: req.signal) // a lab token talks to no bot: its first use takes over
      let lang = Langs.replyLang(record.siriLang)
      guard let lab = d.lab else { return stop(404, Lab.off(lang)) }
      if await overLimit(record.id) { return stop(200, Messages.of(lang).rateLimited) }
      let r = await lab.handle(LabStep(
        run: body["run"]?.string ?? "", step: VoiceAPI.int(body["step"], -1), last: VoiceAPI.int(body["last"], 10),
        text: body["text"]?.string ?? "", tokenId: record.id, lang: lang, signal: req.signal))
      if req.signal.isCancelled { return .gone }
      return .json(200, JSOut.loop(r))
    } catch {
      d.log(["event": "request-error", "error": .string(Log.errorName(error)), "kind": "lab"])
      return stop(500, Messages.of(nil).internalError)
    }
  }

  /// Siri wait-limit probe: answer after the next delay and log whether the client was still
  /// there. Only wait-test tokens: a voice Shortcut's token is never activated or retired here
  /// (M4 review S2). Talks to no bot, so a wait-test token takes over on its first use.
  func probe(_ req: VoiceRequest) async throws -> VoiceResponse {
    guard case .ok(let record, _) = try await d.admit(req.token, nil, .probe, true) else { return .text(401, Messages.of(.en).badToken) }
    await takeOver(record, signal: req.signal)
    let steps = Catalogs.probeSteps
    let s = steps[probeIdx % steps.count]
    probeIdx += 1
    let t0 = d.now()
    d.log(["event": "probe-start", "s": .int(s)])
    _ = await req.signal.sleep(ms: s * d.probeUnitMs)
    let delivered = !req.signal.isCancelled
    var e: LogEvent = ["event": "probe-end", "s": .int(s), "delivered": .bool(delivered)]
    if !delivered { e["client_gave_up_ms"] = .int(Int(d.now() - t0)) }
    d.log(e)
    return delivered ? .text(200, Catalogs.probeText(Langs.replyLang(record.siriLang), s)) : .gone
  }

  /// One-time Shortcut download (DESIGN §7.8). The id is a bearer secret: never logged; unknown,
  /// used and expired links look the same.
  func download(_ id: String) async -> VoiceResponse {
    let link = await d.downloads?.take(id)
    let data = link.flatMap { try? Data(contentsOf: $0.file) }
    d.log(["event": "download", "outcome": data != nil ? "served" : "gone"])
    guard let link, let data else { return .text(404, "This link has expired or was already used. Make a new one in Homebot.") }
    let encoded = link.name.addingPercentEncoding(withAllowedCharacters: VoiceAPI.uriUnreserved) ?? "Homebot"
    return VoiceResponse(status: 200, headers: [
      "content-type": "application/octet-stream",
      "content-disposition": "attachment; filename=\"Homebot.shortcut\"; filename*=UTF-8''\(encoded).shortcut",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
    ], body: data)
  }

  /// What `encodeURIComponent` leaves alone.
  static let uriUnreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
}
