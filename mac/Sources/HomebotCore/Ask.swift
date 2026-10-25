// AskService: one voice question -> one owned bot reply, within one hard deadline (DESIGN §4).
// Authentication and authorization (T3) happen in the gateway before this is called; the request
// carries the authorized session, and the turn never looks the bot up again by key to choose a
// conversation. Ported from src/core/ask.ts.
//
// Cancellation: the work runs in its own task, cancelled by the deadline or by the request's
// CancelSignal (the HTTP client left). Which one fired decides the outcome; the phase (before or
// after the send started) decides the spoken line, so "not sent" is said only when nothing was.
import Foundation

/// The credential a bot turn uses, resolved once at the turn's start (DESIGN §20.4).
public struct BdkSession: Sendable {
  public let client: BdkClient
  /// The credential generation the turn reports its result for.
  public let generation: Int
  /// The key itself, only to remove it from text before speech and storage (A1).
  public let key: String

  public init(client: BdkClient, generation: Int = 0, key: String = "") {
    self.client = client
    self.generation = generation
    self.key = key
  }
}

/// Nil: no credential configured (the turn answers "sign in again").
public typealias BdkProvider = @Sendable () async -> BdkSession?

/// `POST /messages` delivery values that mean the message was taken (as in @cursor/bdk).
let acceptedDeliveries: Set<String> = ["accepted_temporal", "duplicate"]

/// Busy rule as in @cursor/bdk's grokbot-agents extension, plus `idle === false` (probe P1).
public func isBusy(_ turn: Turn?) -> Bool {
  guard let turn else { return false }
  if turn.idle == .bool(false) || turn.inFlight == .bool(true) { return true }
  if case .number(let q) = turn.queued, q > 0 { return true }
  return false
}

/// One character per poll for the log: `B` busy, `I` a fully valid idle state
/// (`idle: true, inFlight: false, queued: 0`), `?` anything else.
public func turnCode(_ turn: Turn?) -> Character {
  if isBusy(turn) { return "B" }
  if let t = turn, t.idle == .bool(true), t.inFlight == .bool(false), t.queued == .number(0) { return "I" }
  return "?"
}

public actor AskService {
  public struct TraceIdle: Sendable {
    public var maxMs: Int
    public var everyMs: Int
    public init(maxMs: Int, everyMs: Int) {
      self.maxMs = maxMs
      self.everyMs = everyMs
    }
  }

  let config: ConfigStore
  let state: StateStore
  let bdk: BdkProvider
  let log: LogFn
  let warmMaxPages: Int
  /// Turn-tail tracing (DESIGN §18.3): off when `maxMs` is 0.
  let traceIdle: TraceIdle
  /// Called with the turn's credential generation once Grok Bot accepted or rejected it.
  let onCredential: @Sendable (_ generation: Int, _ accepted: Bool) async -> Void
  /// Sessions with a request in flight (the guard is per session, not per key).
  public private(set) var inFlight: Set<String> = []
  var tails: [String: CancelSignal] = [:]
  var persisting: Task<Void, Never> = Task {}
  /// Test hook: replaces the state store's cursor write.
  let writeCursor: (@Sendable (_ key: String, _ cursor: String, _ maxSeq: String, _ sessionId: String) async throws -> Void)?

  public init(
    config: ConfigStore, state: StateStore, bdk: @escaping BdkProvider, log: @escaping LogFn = { _ in }, warmMaxPages: Int = 20,
    traceIdle: TraceIdle = TraceIdle(maxMs: 0, everyMs: 1000),
    onCredential: @escaping @Sendable (Int, Bool) async -> Void = { _, _ in },
    writeCursor: (@Sendable (String, String, String, String) async throws -> Void)? = nil
  ) {
    self.config = config
    self.state = state
    self.bdk = bdk
    self.log = log
    self.warmMaxPages = warmMaxPages
    self.traceIdle = traceIdle
    self.onCredential = onCredential
    self.writeCursor = writeCursor
  }

  /// Why the work was stopped from outside.
  enum Abort: Sendable { case deadline, disconnect }

  /// Mutable state of one turn, shared by its work task and the code that finishes it.
  final class Run: @unchecked Sendable {
    private let lock = NSLock()
    private var _abort: Abort?
    private var _phase = "before-send"
    private var _pos: (cursor: String, maxSeq: String)
    private var _timings: [String: Int] = [:]
    private var _interim: Int?
    let t0 = Date()

    init(cursor: String, maxSeq: String) { _pos = (cursor, maxSeq) }

    var abort: Abort? { lock.withLock { _abort } }
    func setAbort(_ a: Abort) { lock.withLock { if _abort == nil { _abort = a } } }
    var phase: String {
      get { lock.withLock { _phase } }
      set { lock.withLock { _phase = newValue } }
    }
    var pos: (cursor: String, maxSeq: String) {
      get { lock.withLock { _pos } }
      set { lock.withLock { _pos = newValue } }
    }
    var timings: [String: Int] { lock.withLock { _timings } }
    /// Untagged deliveries seen after our message while no tagged one has arrived (strict mode).
    var interim: Int? {
      get { lock.withLock { _interim } }
      set { lock.withLock { _interim = newValue } }
    }
    var elapsedMs: Int { Int(Date().timeIntervalSince(t0) * 1000) }
    func mark(_ k: String) { lock.withLock { _timings[k] = Int(Date().timeIntervalSince(t0) * 1000) } }
    func bump(_ k: String) { lock.withLock { _timings[k, default: 0] += 1 } }
  }

  struct Done: Error {
    let result: AskResult
  }

  public func ask(_ req: AskRequest) async -> AskResult {
    let t0 = Date()
    // Bots may have been added or removed by the app or another CLI process.
    try? await config.refresh()
    try? await state.refresh()
    let settings = await config.settings
    let bot = await config.bot(req.botKey)
    let m = Messages.of(req.lang)
    let question = req.text.trimmingCharacters(in: jsWhitespace)
    let log = self.log
    func done(_ outcome: String, _ say: String, reason: String? = nil, requestId: String? = nil, timings: [String: Int] = [:], turns: String = "", delivery: Int? = nil, interim: Int? = nil, extra: LogEvent = [:]) -> AskResult {
      var t = timings
      t["total_ms"] = Int(Date().timeIntervalSince(t0) * 1000)
      var e: LogEvent = ["event": "ask", "bot": .string(req.botKey), "outcome": .string(outcome), "q_len": .int(question.count)]
      if let reason { e["reason"] = .string(reason) }
      if let requestId { e["requestId"] = .string(requestId) }
      if !turns.isEmpty { e["turns"] = .string(turns) }
      if let delivery { e["delivery"] = .int(delivery) }
      if let interim { e["interim"] = .int(interim) }
      for (k, v) in t { e[k] = .int(v) }
      for (k, v) in extra { e[k] = v }
      log(e)
      return AskResult(text: say, outcome: outcome, reason: reason, timings: t, requestId: requestId, delivery: delivery, interim: interim)
    }

    // The authorized session must still be this bot's conversation; a cursor tagged with another
    // conversation is not this bot's position.
    guard let bot, req.sessionId.map({ $0 == bot.sessionId }) ?? true,
          let cur = await state.cursor(bot.key), cur.sessionId.map({ $0 == bot.sessionId }) ?? true
    else { return done("not-configured", m.botNotConfigured) }
    // A new request ends the previous answer's tail trace: from here on the session is ours again.
    tails[bot.sessionId]?.cancel()
    if question.isEmpty { return done("empty", m.emptyQuestion) }
    if question.unicodeScalars.count > settings.maxQuestionChars { return done("too-long", m.tooLong) }
    if inFlight.contains(bot.sessionId) { return done("in-flight", m.inFlight(bot.name)) }
    if req.signal?.isCancelled == true {
      // The client left before anything happened (e.g. while the token was activated).
      return done("not-sent:disconnect", m.notSent, requestId: Envelope.newRequestId())
    }

    inFlight.insert(bot.sessionId)
    let requestId = Envelope.newRequestId()
    let run = Run(cursor: cur.cursor, maxSeq: cur.maxSeq)
    let session = await bdk()
    let traceIdle = self.traceIdle
    let warmMaxPages = self.warmMaxPages
    let onCredential = self.onCredential
    let secrets = [session?.key ?? ""] + req.redact
    let turnsBox = TurnsBox()
    let sawUser = Flag()

    let work = Task<AskResult, Never> {
      func finish(_ outcome: String, _ say: String, reason: String? = nil, delivery: Int? = nil, interim: Int? = nil, extra: LogEvent = [:]) -> AskResult {
        done(outcome, say, reason: reason, requestId: requestId, timings: run.timings, turns: turnsBox.value, delivery: delivery, interim: interim, extra: extra)
      }
      guard let session else { return finish("auth-failed", m.authFailed, extra: ["phase": "before-send"]) }
      let client = session.client
      func fetchPage(_ c: String) async throws -> Page {
        try await client.getEntries(sessionId: bot.sessionId, afterUpdatedSeq: c)
      }
      do {
        // Baseline: warm sync from the persisted cursor to the real end; transient errors retry
        // within the same deadline. A follow-up that may wait judges user entries from its arrival
        // on, the first sync included (conversation review B1).
        let watch: (([Entry]) -> Void)? = req.waitIdleMs > 0 ? { es in if es.contains(where: { $0.role == "user" }) { sawUser.set() } } : nil
        var base = try await syncToEnd(cursor: run.pos.cursor, maxSeq: run.pos.maxSeq, maxPages: warmMaxPages, onEntries: watch) { c in
          try await retrying(3) { try await fetchPage(c) }
        }
        await onCredential(session.generation, true)
        run.pos = (base.cursor, base.maxSeq)
        run.mark("baseline_ms")
        if isBusy(base.turn) && req.waitIdleMs > 0 {
          // A scheduling allowance, never evidence of ownership: the baseline is taken only after
          // the wait, and any user entry that arrived meanwhile refuses the follow-up (§18.3).
          let until = Date().addingTimeInterval(Double(req.waitIdleMs) / 1000)
          if sawUser.isSet { return finish("busy", m.busy(bot.name), extra: ["wait": "user"]) }
          while isBusy(base.turn) {
            // Never sleep past the allowance (conversation review S4), and never poll without a
            // sleep: a remainder under 1 ms used to round to a zero sleep and spin on the API.
            let left = until.timeIntervalSinceNow
            if left <= 0 { break }
            try await Task.sleep(nanoseconds: UInt64(min(Double(max(settings.pollMs, 1)) / 1000, left) * 1_000_000_000))
            base = try await syncToEnd(cursor: run.pos.cursor, maxSeq: run.pos.maxSeq, maxPages: warmMaxPages, onEntries: watch) { c in
              try await retrying(3) { try await fetchPage(c) }
            }
            run.pos = (base.cursor, base.maxSeq)
            if sawUser.isSet { return finish("busy", m.busy(bot.name), extra: ["wait": "user"]) }
          }
          run.mark("idle_wait_ms")
        }
        if isBusy(base.turn) { return finish("busy", m.busy(bot.name)) }
        // The last point where nothing has been sent.
        try Task.checkCancellation()
        if run.abort != nil { throw CancellationError() }
        // A token revoked or narrowed while the turn waited sends nothing (T3).
        if let still = req.stillGranted, !(await still()) { return finish("revoked", m.botNotConfigured, extra: ["phase": "before-send"]) }

        run.phase = "sent"
        let envelope = Envelope.build(id: requestId, text: question, lang: req.lang, strictEcho: bot.strictEcho, style: bot.style, test: req.test, turn: req.turn)
        // Same messageId on every attempt: the API answers `duplicate` if one already arrived.
        let sent = try await retrying(4) { try await client.sendMessage(sessionId: bot.sessionId, messageId: requestId, text: envelope) }
        run.mark("sent_ms")
        // Any other delivery means "not accepted"; we can't be sure nothing arrived, so we say it
        // may have been delivered, but stop waiting. The value itself is never logged.
        if let d = sent.delivery, !acceptedDeliveries.contains(d) {
          return finish("not-accepted", m.noReplyInTime(bot.name), extra: ["delivery": "unknown"])
        }

        var seen: [Entry] = []
        // True only when the last poll read every page to the end (milestone review B1).
        var complete = true
        // Consecutive complete polls that saw the turn fully idle.
        var idlePolls = 0
        while true {
          // One ownership decision over every version seen so far; only one proved delivery is
          // spoken: the first that carries our echo tag (BDK review B1, B2; DECISIONS item 26).
          let d = try decideReply(seen, baseMaxSeq: base.maxSeq, requestId: requestId, strictEcho: bot.strictEcho)
          if case .refuse(let why, _, _) = d { return finish("refused", m.refused, reason: why.rawValue, interim: run.interim) }
          if case .unproved(let n, _) = d {
            // Idle polls count only from the latest interim delivery on.
            if n != run.interim { idlePolls = 0 }
            run.interim = n
            // Only untagged output and the turn has ended: no tagged reply is coming. Two idle
            // polls in a row, so a delivery written just before the turn went idle is still read.
            if complete && idlePolls >= 2 { return finish("refused", m.refused, reason: Refusal.O5.rawValue, interim: n, extra: ["end": "idle"]) }
          }
          if case .accept(let text, _, _, let skipped) = d, complete {
            run.mark("reply_ms")
            let cleaned = ProtocolFilter.clean(text, requestId: requestId, secrets: secrets)
            let say = Speech.speakable(cleaned, settings.maxSpoken(req.lang.rawValue))
            if say.isEmpty { return finish("unspeakable", m.unspeakable) }
            // Revoked while the bot answered: the answer is not returned (T3).
            if let still = req.stillGranted, !(await still()) { return finish("revoked", m.botNotConfigured, extra: ["phase": "after-reply"]) }
            return finish("answered", say, delivery: skipped + 1, interim: skipped, extra: ["a_len": .int(say.count)])
          }
          let wait = run.elapsedMs > 10_000 ? settings.pollMs * 2 : settings.pollMs
          try await Task.sleep(nanoseconds: UInt64(max(wait, 0)) * 1_000_000)
          do {
            // Entries go into `seen` page by page: if a later page fails, the evidence already
            // fetched still counts (BDK re-review R1).
            var got: [Entry] = []
            defer { seen.append(contentsOf: got) }
            let page = try await syncToEnd(cursor: run.pos.cursor, maxSeq: run.pos.maxSeq, maxPages: 5, onEntries: { got.append(contentsOf: $0) }, fetchPage: fetchPage)
            run.pos = (page.cursor, page.maxSeq)
            complete = true
            turnsBox.add(turnCode(page.turn))
            idlePolls = turnCode(page.turn) == "I" ? idlePolls + 1 : 0
          } catch {
            complete = false
            idlePolls = 0
            if Task.isCancelled || run.abort != nil { throw error }
            if let b = error as? BdkError, b.kind == .auth { throw error }
            run.bump("poll_errors") // transient; keep polling until the deadline
          }
        }
      } catch {
        if let a = run.abort {
          let why = a == .deadline ? "deadline" : "disconnect"
          // Only untagged output by the deadline: a reply arrived but none is proved ours (O5).
          if a == .deadline, let n = run.interim { return finish("refused", m.refused, reason: Refusal.O5.rawValue, interim: n, extra: ["end": "deadline"]) }
          return run.phase == "before-send" ? finish("not-sent:\(why)", m.notSent) : finish("no-reply:\(why)", m.noReplyInTime(bot.name))
        }
        if let b = error as? BdkError, b.kind == .auth {
          await onCredential(session.generation, false)
          return finish("auth-failed", m.authFailed, extra: ["phase": .string(run.phase)])
        }
        if error is HistoryTooLongError { return finish("history-too-long", m.botNotConfigured) }
        if let b = error as? BdkError {
          // A 4xx rejection means nothing was accepted. Network/5xx after sending started is uncertain.
          let uncertain = run.phase == "sent" && b.kind != .request
          return uncertain
            ? finish("no-reply:upstream", m.noReplyInTime(bot.name), extra: ["status": .int(b.status ?? 0)])
            : finish("upstream", m.upstreamDown, extra: ["phase": .string(run.phase), "status": .int(b.status ?? 0)])
        }
        return finish("error", m.internalError, extra: ["phase": .string(run.phase), "error": .string(Log.errorName(error))])
      }
    }
    let timer = Task {
      try? await Task.sleep(nanoseconds: UInt64(max(settings.answerBudgetMs, 0)) * 1_000_000)
      if !Task.isCancelled {
        run.setAbort(.deadline)
        work.cancel()
      }
    }
    let reg = req.signal?.onCancel {
      run.setAbort(.disconnect)
      work.cancel()
    }
    let result = await work.value
    timer.cancel()
    if let reg { req.signal?.remove(reg) }
    inFlight.remove(bot.sessionId)
    persistCursor(bot, run.pos)
    if result.outcome == "answered", traceIdle.maxMs > 0, let session { traceTail(bot, requestId: requestId, from: run.pos, client: session.client) }
    return result
  }

  /// Diagnostics only (DESIGN §18.3): after an answer was returned, poll the session (GET only)
  /// until its turn is fully idle, and log how long that took (`turn-tail`). It holds no guard,
  /// moves no persisted cursor and decides nothing; a new request for the session stops it.
  func traceTail(_ bot: Bot, requestId: String, from: (cursor: String, maxSeq: String), client: BdkClient) {
    let stop = CancelSignal()
    tails[bot.sessionId] = stop
    let cfg = traceIdle
    let log = self.log
    struct Tail: Sendable {
      var outcome = "timeout"
      var polls = 0
      var userEntries = 0
      var deliveries = 0
    }
    Task {
      let t0 = Date()
      let superseded = Flag()
      let work = Task<Tail, Never> {
        var t = Tail()
        var pos = from
        do {
          while true {
            try await Task.sleep(nanoseconds: UInt64(cfg.everyMs) * 1_000_000)
            var seen: [Entry] = []
            let page = try await syncToEnd(cursor: pos.cursor, maxSeq: pos.maxSeq, maxPages: 5, onEntries: { seen.append(contentsOf: $0) }) { c in
              try await client.getEntries(sessionId: bot.sessionId, afterUpdatedSeq: c)
            }
            for e in seen {
              if e.role == "user" { t.userEntries += 1 } else if e.kind == "send-message" { t.deliveries += 1 }
            }
            pos = (page.cursor, page.maxSeq)
            t.polls += 1
            if turnCode(page.turn) == "I" {
              t.outcome = "idle"
              return t
            }
          }
        } catch {
          t.outcome = Task.isCancelled ? (superseded.isSet ? "superseded" : "timeout") : "error:\(Log.errorName(error))"
          return t
        }
      }
      let reg = stop.onCancel {
        superseded.set()
        work.cancel()
      }
      let timer = Task {
        try? await Task.sleep(nanoseconds: UInt64(cfg.maxMs) * 1_000_000)
        work.cancel()
      }
      let t = await work.value
      timer.cancel()
      stop.remove(reg)
      self.endTail(bot.sessionId, stop)
      var e: LogEvent = ["event": "turn-tail", "bot": .string(bot.key), "requestId": .string(requestId), "outcome": .string(t.outcome), "polls": .int(t.polls), "user_entries": .int(t.userEntries), "deliveries": .int(t.deliveries)]
      if t.outcome == "idle" { e["idle_after_ms"] = .int(Int(Date().timeIntervalSince(t0) * 1000)) }
      log(e)
    }
  }

  private func endTail(_ sid: String, _ s: CancelSignal) {
    if tails[sid] === s { tails[sid] = nil }
  }

  /// Stop all tail traces (shutdown, tests).
  public func stop() {
    for s in tails.values { s.cancel() }
  }

  /// Ordered, forward-only cursor writes off the response path; failures are logged, not thrown.
  /// Tagged with the session, and skipped if the bot was removed or re-added meanwhile.
  func persistCursor(_ bot: Bot, _ pos: (cursor: String, maxSeq: String)) {
    let prev = persisting
    let config = self.config
    let state = self.state
    let log = self.log
    let write = self.writeCursor
    persisting = Task {
      await prev.value
      do {
        try await config.refresh()
        guard await config.bot(bot.key)?.sessionId == bot.sessionId else { return }
        if let write {
          try await write(bot.key, pos.cursor, pos.maxSeq, bot.sessionId)
        } else {
          try await state.setCursor(bot.key, cursor: pos.cursor, maxSeq: pos.maxSeq, sessionId: bot.sessionId)
        }
      } catch {
        log(["event": "persist-error", "bot": .string(bot.key), "error": .string(Log.errorName(error))])
      }
    }
  }

  /// Wait for pending cursor writes (shutdown, tests).
  public func flush() async {
    await persisting.value
  }
}

/// Run `fn`, retrying network/5xx BDK errors with a short backoff while the task is not
/// cancelled. Auth and 4xx errors are not retried.
func retrying<T: Sendable>(_ retries: Int, _ fn: () async throws -> T) async throws -> T {
  var attempt = 0
  while true {
    do {
      return try await fn()
    } catch {
      try Task.checkCancellation()
      guard let b = error as? BdkError, b.kind == .network || b.kind == .upstream, attempt < retries else { throw error }
      attempt += 1
      try await Task.sleep(nanoseconds: UInt64(200 * attempt) * 1_000_000)
    }
  }
}

final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var v = false
  func set() { lock.withLock { v = true } }
  var isSet: Bool { lock.withLock { v } }
}

/// Turn codes per poll after sending (diagnostics only; never used to decide ownership).
final class TurnsBox: @unchecked Sendable {
  private let lock = NSLock()
  private var s = ""
  func add(_ c: Character) { lock.withLock { if s.count < 80 { s.append(c) } } }
  var value: String { lock.withLock { s } }
}
