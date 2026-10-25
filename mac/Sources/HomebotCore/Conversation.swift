// Conversation mode (DESIGN §18): a looping Shortcut asks, the gateway answers and says whether
// to listen again. One invocation is a run; each listen-and-POST is a step. The Shortcut holds no
// policy: end words, silence and the step cap are decided here. Every bot turn goes through the
// ask service unchanged, so strict ownership (§4.2) applies to each answer. Nothing said is logged;
// the log holds run id prefixes, steps, outcomes and lengths. Ported from src/core/conversation.ts.
// The single-entry choosing phase (DESIGN §20.5) extends this in S4.
import Foundation

/// One question for the ask service.
public struct AskRequest: Sendable, Equatable {
  public var botKey: String
  /// The session the token's grant authorized (DESIGN §20.5 T3): the turn uses exactly this
  /// conversation and never looks the bot up again by key. Nil only in tests.
  public var sessionId: String?
  public var text: String
  /// Reply language from the Shortcut's Siri language.
  public var lang: ReplyLang
  public var test: Bool
  /// The bot turn within a conversation run (DESIGN §18.4); nil for one-shot questions.
  public var turn: Int?
  /// Follow-up inside a run whose previous turn was answered (DESIGN §18.3): wait up to this long
  /// for the session to go idle instead of answering "busy" at once. 0: no wait.
  public var waitIdleMs: Int
  /// Fired when the HTTP client disconnects.
  public var signal: CancelSignal?
  /// Exact strings removed from the answer before it is spoken (the request's token, A1).
  public var redact: [String]
  /// Whether the token still grants this bot (DESIGN §20.5 T3): checked right before the
  /// question is sent and again before an answer is returned. Nil: no check (tests).
  public var stillGranted: (@Sendable () async -> Bool)?

  public init(botKey: String, sessionId: String? = nil, text: String, lang: ReplyLang = .en, test: Bool = false, turn: Int? = nil, waitIdleMs: Int = 0, signal: CancelSignal? = nil, redact: [String] = [], stillGranted: (@Sendable () async -> Bool)? = nil) {
    self.botKey = botKey
    self.sessionId = sessionId
    self.text = text
    self.lang = lang
    self.test = test
    self.turn = turn
    self.waitIdleMs = waitIdleMs
    self.signal = signal
    self.redact = redact
    self.stillGranted = stillGranted
  }

  /// The signal, the secrets and the grant check are not part of a request's identity.
  public static func == (a: AskRequest, b: AskRequest) -> Bool {
    a.botKey == b.botKey && a.sessionId == b.sessionId && a.text == b.text && a.lang == b.lang && a.test == b.test && a.turn == b.turn && a.waitIdleMs == b.waitIdleMs
  }
}

public struct AskResult: Sendable, Equatable {
  public var text: String
  public var outcome: String
  public var reason: String?
  public var timings: [String: Int]
  /// The wire request id (logged; never stored in activity, A4).
  public var requestId: String?
  /// Which text delivery after our message was spoken (1-based), and how many untagged interim
  /// deliveries were skipped (DESIGN §4.2). Counts only, never text.
  public var delivery: Int?
  public var interim: Int?

  public init(text: String, outcome: String, reason: String? = nil, timings: [String: Int] = [:], requestId: String? = nil, delivery: Int? = nil, interim: Int? = nil) {
    self.text = text
    self.outcome = outcome
    self.reason = reason
    self.timings = timings
    self.requestId = requestId
    self.delivery = delivery
    self.interim = interim
  }
}

public typealias AskFn = @Sendable (AskRequest) async throws -> AskResult

public enum Conversation {
  /// Steps per run, fixed in the Shortcut: the gateway can end a run earlier, never later.
  public static let steps = 10

  /// Comparison form for end words: NFKC, lower case, punctuation and symbols removed, single spaces.
  static func norm(_ s: String) -> String {
    let t = s.precomposedStringWithCompatibilityMapping.lowercased()
    let stripped = t.replacingOccurrences(of: #"[\p{P}\p{S}]"#, with: "", options: .regularExpression)
    return stripped.replacingOccurrences(of: #"[\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: jsWhitespace)
  }

  /// Whole utterances that end a run (DESIGN §18.2, Q18-2).
  public static func isEndWord(_ text: String, _ lang: ReplyLang) -> Bool {
    (endWords[lang] ?? []).contains(norm(text))
  }

  /// The end word to tell the user about: the first of the language's list.
  public static func endWord(_ lang: ReplyLang) -> String {
    endWords[lang]?.first ?? "stop"
  }
}

public struct ConversationStep: Sendable {
  public var run: String
  public var step: Int
  public var last: Int
  public var text: String
  /// The Shortcut's own first question, spoken at the start of a run.
  public var prompt: String
  /// The bot the request names (or the one-bot token's bot); nil for the entry flow.
  public var botKey: String?
  /// The authorized grant's session (T3); the run is pinned to key and session.
  public var sessionId: String?
  public var tokenId: String
  public var lang: ReplyLang
  /// Fired when this request's HTTP client disconnects. A step's work observes the signal of the
  /// request that started it, so its retries share its outcome (TypeScript parity).
  public var signal: CancelSignal?
  /// Removed from answers before they are spoken (the request's token, A1).
  public var redact: [String]
  /// The entry flow (DESIGN §20.5): set for a run started without a bot.
  public var entry: EntryContext?

  public init(run: String, step: Int, last: Int, text: String, prompt: String, botKey: String?, sessionId: String? = nil, tokenId: String, lang: ReplyLang, signal: CancelSignal? = nil, redact: [String] = [], entry: EntryContext? = nil) {
    self.sessionId = sessionId
    self.run = run
    self.step = step
    self.last = last
    self.text = text
    self.prompt = prompt
    self.botKey = botKey
    self.tokenId = tokenId
    self.lang = lang
    self.signal = signal
    self.redact = redact
    self.entry = entry
  }
}

/// What the entry flow needs from the gateway for one request.
public struct EntryContext: Sendable {
  /// The token's live grants (session still current), in the set's order, with their names now.
  public var choices: @Sendable () async -> [EntryChoice]
  /// Admit the chosen grant and mark the token used, in one locked step (T3); false when it no
  /// longer holds. The takeover (T5) waits for the run's first answer.
  public var pin: @Sendable (BotGrant) async -> Bool

  public init(choices: @escaping @Sendable () async -> [EntryChoice], pin: @escaping @Sendable (BotGrant) async -> Bool) {
    self.choices = choices
    self.pin = pin
  }
}

/// What one step did, for the activity record (DESIGN §20.6 A1). Nil for steps that did no work
/// (a run's start, a retry answered from the cache).
public struct StepActivity: Sendable, Equatable {
  public var outcome: String
  public var step: Int
  /// The bot of a bot turn or a choice; nil before a choice.
  public var botKey: String?
  public var botName: String?
  /// The question as said, for bot turns only (choosing steps keep no text).
  public var question: String?
  /// The bot turn's result (timings, reason).
  public var ask: AskResult?
}

public struct StepReply: Sendable, Equatable {
  public var response: LoopResponse
  public var activity: StepActivity?
}

public actor ConversationService {
  public enum Phase: Sendable, Equatable {
    /// The menu `snapshot` was spoken; `misses` answers matched nothing.
    case choosing(snapshot: [EntryChoice], misses: Int)
    /// A close name was asked back as a yes/no question.
    case confirming(EntryChoice, snapshot: [EntryChoice], misses: Int)
    case pinned
  }

  public struct RunState: Sendable {
    var botKey: String?
    var sessionId: String?
    var botName: String?
    var lang: ReplyLang
    /// The Shortcut's step cap, as sent at the start.
    var last: Int
    /// Bot turns taken in this run.
    var turns: Int
    /// Whether the previous bot turn of this run was answered (enables the follow-up wait).
    var answered: Bool
    /// Entry flow only (DESIGN §20.5).
    var entry = false
    var phase: Phase = .pinned
    /// The question prompt said after a choice.
    var prompt = ""
    /// The step right after an exact choice, where a "no" word goes back to the menu once.
    var justChosen = false
    var mayReturn = true
  }

  public let runs: RunStore<RunState, StepReply>
  let ask: AskFn
  let log: LogFn
  /// Current follow-up idle wait (DESIGN §18.3); read per step so a config change applies.
  let followupIdleMs: @Sendable () -> Int
  /// Whether the token still grants this exact (key, session) pair (DESIGN §20.5 rule 3); checked
  /// before every step, including a retry answered from the cache.
  let stillGranted: @Sendable (_ tokenId: String, _ grant: BotGrant) async -> Bool

  public init(ask: @escaping AskFn, log: @escaping LogFn = { _ in }, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }, followupIdleMs: @escaping @Sendable () -> Int = { 0 }, stillGranted: @escaping @Sendable (String, BotGrant) async -> Bool = { _, _ in true }) {
    self.ask = ask
    self.stillGranted = stillGranted
    self.log = log
    self.followupIdleMs = followupIdleMs
    runs = RunStore(now: now)
  }

  public func handle(_ s: ConversationStep) async -> LoopResponse {
    await step(s).response
  }

  public func step(_ s: ConversationStep) async -> StepReply {
    let m = Messages.of(s.lang)
    let log = self.log
    if s.step == 0 { return await start(s) }
    let run = s.run
    func restart(_ r: String) -> StepReply {
      StepReply(response: LoopResponse(say: m.restart, ask: m.more, mode: .v1, next: .end, run: r), activity: StepActivity(outcome: "restart", step: s.step))
    }
    guard RunStore<RunState, StepReply>.isRunId(run) else {
      log(["event": "conversation", "run": "invalid", "step": .int(s.step), "outcome": "unknown"])
      return restart("")
    }
    let runs = self.runs
    let ask = self.ask
    let followup = min(max(followupIdleMs(), 0), 10_000)
    let step = s.step
    let text = s.text
    let botKey = s.botKey
    let sessionId = s.sessionId
    let tokenId = s.tokenId
    let signal = s.signal
    let redact = s.redact
    let entry = s.entry
    let stillGranted = self.stillGranted
    // The run's pinned grant must still hold (rule 3): checked before the step and again before
    // any answer is returned, so a revocation while the bot was answering suppresses the answer,
    // also for a cached retry.
    func revoked() async -> Bool {
      // Only the run's own token: another token's request is refused by the claim below and never
      // ends a run it does not own.
      guard let pinned = await runs.state(run, ownedBy: tokenId), let key = pinned.botKey, let sid = pinned.sessionId else { return false }
      return !(await stillGranted(tokenId, BotGrant(key: key, sessionId: sid)))
    }
    func revokedReply() async -> StepReply {
      await runs.finish(run)
      log(["event": "conversation", "run": .string(String(run.prefix(6))), "step": .int(step), "outcome": "revoked"])
      let st = await runs.state(run)
      return StepReply(response: LoopResponse(say: m.botNotConfigured, ask: m.more, mode: .v1, next: .end, run: run), activity: StepActivity(outcome: "revoked", step: step, botKey: st?.botKey, botName: st?.botName))
    }
    if await revoked() { return await revokedReply() }
    // A request for an entry run names no bot; a request for a pinned run names exactly its bot.
    let accept: @Sendable (RunState) -> Bool = { st in st.entry ? botKey == nil && entry != nil : st.botKey == botKey && st.sessionId == sessionId }
    let claim = await runs.claim(run, tokenId: s.tokenId, step: step, input: text, accept: accept) { state in
      func stop(_ say: String, _ outcome: String, bot: (String?, String?) = (nil, nil), question: String? = nil) async -> StepReply {
        await runs.finish(run)
        // The log keeps the TypeScript name for silence ("empty"); activity uses A2's code.
        log(["event": "conversation", "run": .string(String(run.prefix(6))), "step": .int(step), "outcome": .string(outcome == "silence" ? "empty" : outcome)])
        return StepReply(response: LoopResponse(say: say, ask: m.more, mode: .v1, next: .end, run: run), activity: StepActivity(outcome: outcome, step: step, botKey: bot.0, botName: bot.1, question: question))
      }
      if state.entry, let entry, state.phase != .pinned || state.justChosen {
        if let r = await ConversationService.choose(state: state, text: text, step: step, run: run, runs: runs, entry: entry, m: m, log: log) { return r }
      }
      let pinned = (state.botKey, state.botName)
      // Silence and end words end the run; nothing reaches the bot.
      if Conversation.norm(text).isEmpty { return await stop(m.goodbye, "silence", bot: pinned) }
      if Conversation.isEndWord(text, state.lang) { return await stop(m.goodbye, "end-word", bot: pinned) }
      guard let key = state.botKey else { return await stop(m.restart, "restart") }
      let turn = state.turns + 1
      await runs.update(run) {
        $0.turns = turn
        $0.justChosen = false
      }
      let r: AskResult
      do {
        r = try await ask(AskRequest(botKey: key, sessionId: state.sessionId, text: text, lang: state.lang, turn: turn, waitIdleMs: state.answered ? followup : 0, signal: signal, redact: redact, stillGranted: { await stillGranted(tokenId, BotGrant(key: key, sessionId: state.sessionId ?? "")) }))
      } catch {
        // A step that fails ends its run, and retries get this same answer (review S2).
        return await stop(m.internalError, "error", bot: pinned, question: text)
      }
      let answered = r.outcome == "answered"
      await runs.update(run) { $0.answered = answered }
      // Only a proved answer keeps listening; every refusal, error or timeout ends the run.
      let end = !answered || step >= state.last
      if end { await runs.finish(run) }
      log(["event": "conversation", "run": .string(String(run.prefix(6))), "step": .int(step), "turn": .int(turn), "outcome": .string(r.outcome), "next": .string(end ? "end" : "listen")])
      return StepReply(
        response: LoopResponse(say: r.text, ask: m.more, mode: .v1, next: end ? .end : .listen, run: run),
        activity: StepActivity(outcome: r.outcome, step: step, botKey: key, botName: state.botName, question: text, ask: r))
    }
    switch claim {
    case .taken(let task):
      let r = await task.value
      return await revoked() ? await revokedReply() : r
    case .refused(let c):
      // A retry is answered only for the bot its run belongs to (conversation review N1); it adds
      // no activity record (A1: logical steps, not HTTP attempts).
      if case .repeat(let response, let state) = c, accept(state) {
        log(["event": "conversation", "run": .string(String(run.prefix(6))), "step": .int(step), "repeat": true])
        let r = await response.value
        return await revoked() ? await revokedReply() : StepReply(response: r.response, activity: nil)
      }
      let outcome: String
      switch c {
      case .next, .repeat: outcome = "other-bot"
      default: outcome = c.kind
      }
      // The same token named another bot or session, or changed a step's input: the run ends,
      // so no later step of it is taken (rules 3-4). Unknown runs and other tokens' runs are
      // left alone.
      switch c {
      case .next, .repeat, .changed: await runs.finish(run)
      default: break
      }
      log(["event": "conversation", "run": .string(String(run.prefix(6))), "step": .int(step), "outcome": .string(outcome)])
      return restart(run)
    }
  }

  /// Step 0: a pinned run says the Shortcut's prompt; an entry run pins its only live grant (and
  /// says its name before the prompt) or says the numbered menu.
  func start(_ s: ConversationStep) async -> StepReply {
    let m = Messages.of(s.lang)
    let cap = min(max(s.last, 0), Conversation.steps)
    let trimmed = s.prompt.trimmingCharacters(in: jsWhitespace)
    let first = trimmed.isEmpty ? m.more : jsSlice(trimmed, 200)
    var state = RunState(botKey: s.botKey, sessionId: s.sessionId, lang: s.lang, last: cap, turns: 0, answered: false)
    var say = first
    var mode = LoopResponse.Mode.v2
    var end = cap <= 0
    var activity: StepActivity?
    if s.botKey == nil, let entry = s.entry {
      state.entry = true
      let question = PhraseRow.rows[s.lang]?.promptWithoutBot ?? m.more
      state.prompt = question
      let live = Array(await entry.choices().prefix(TokenStore.maxBots))
      if live.count == 1, let only = live.first {
        // One bot: pinned at once, and its name is said first, so the user hears who answers.
        if await entry.pin(only.grant) {
          state.botKey = only.key
          state.sessionId = only.sessionId
          state.botName = only.name
          say = ChooserText.of(s.lang).chosen(only.spoken, prompt: question)
          activity = StepActivity(outcome: "chosen", step: 0, botKey: only.key, botName: only.name)
        } else {
          say = m.botNotConfigured
          mode = .v1
          end = true
          activity = StepActivity(outcome: "revoked", step: 0)
        }
      } else if live.isEmpty {
        say = m.botNotConfigured
        mode = .v1
        end = true
        activity = StepActivity(outcome: "not-configured", step: 0)
      } else {
        state.phase = .choosing(snapshot: live, misses: 0)
        say = ChooserText.of(s.lang).menu(live)
        // The last step's answer always ends the run (§18.2): a menu needs a step to answer it.
        if cap <= 1 {
          say = ChooserText.of(s.lang).notFound
          mode = .v1
          end = true
          activity = StepActivity(outcome: "no-match", step: 0)
        }
      }
    }
    let r = StepReply(response: LoopResponse(say: say, ask: m.more, mode: mode, next: end ? .end : .listen, run: ""), activity: activity)
    let started = await runs.start(tokenId: s.tokenId, state: state) { id in
      var out = r
      out.response.run = id
      return out
    }
    if end { await runs.finish(started.id) }
    log(["event": "conversation", "run": .string(String(started.id.prefix(6))), "step": 0])
    return await started.response.value
  }

  /// The choosing and confirming steps of an entry run (DESIGN §20.5 rule 2). Nil: the step is
  /// the run's first question (pinned), handled as a bot turn.
  static func choose(state: RunState, text: String, step: Int, run: String, runs: RunStore<RunState, StepReply>, entry: EntryContext, m: Messages, log: LogFn) async -> StepReply? {
    let lang = state.lang
    let t = ChooserText.of(lang)
    let last = step >= state.last
    func reply(_ say: String, _ outcome: String, end: Bool = false, bot: EntryChoice? = nil, mode: LoopResponse.Mode = .v2) async -> StepReply {
      // The last step's answer always ends the run: a menu or question there would go unanswered.
      let stop = end || last
      let say = stop && !end ? t.notFound : say
      let outcome = stop && !end ? "no-match" : outcome
      if stop { await runs.finish(run) }
      log(["event": "conversation", "run": .string(String(run.prefix(6))), "step": .int(step), "outcome": .string(outcome), "next": .string(stop ? "end" : "listen")])
      return StepReply(response: LoopResponse(say: say, ask: m.more, mode: stop ? .v1 : mode, next: stop ? .end : .listen, run: run), activity: StepActivity(outcome: outcome, step: step, botKey: bot?.key, botName: bot?.name))
    }
    func pin(_ c: EntryChoice) async -> Bool {
      guard await entry.pin(c.grant) else { return false }
      await runs.update(run) {
        $0.botKey = c.key
        $0.sessionId = c.sessionId
        $0.botName = c.name
        $0.phase = .pinned
      }
      return true
    }
    /// A miss: say the menu once more (from the live list when `fresh`), or end after the second.
    func miss(_ snapshot: [EntryChoice], _ misses: Int, fresh: Bool = false) async -> StepReply {
      if misses + 1 >= 2 { return await reply(t.notFound, "no-match", end: true) }
      let menu = fresh ? Array(await entry.choices().prefix(TokenStore.maxBots)) : snapshot
      if menu.isEmpty { return await reply(m.botNotConfigured, "not-configured", end: true) }
      await runs.update(run) { $0.phase = .choosing(snapshot: menu, misses: misses + 1) }
      return await reply(t.menu(menu), "no-match")
    }
    if Conversation.isEndWord(text, lang) && state.phase != .pinned { return await reply(m.goodbye, "end-word", end: true) }
    switch state.phase {
    case .pinned:
      // Right after an exact choice: a whole-utterance "no" goes back to the menu, once.
      guard state.justChosen, Chooser.isNo(text, lang) else { return nil }
      guard state.mayReturn else { return await reply(t.notFound, "no-match", end: true) }
      let menu = Array(await entry.choices().prefix(TokenStore.maxBots))
      if menu.isEmpty { return await reply(m.botNotConfigured, "not-configured", end: true) }
      await runs.update(run) {
        $0.botKey = nil
        $0.sessionId = nil
        $0.botName = nil
        $0.justChosen = false
        $0.mayReturn = false
        $0.phase = .choosing(snapshot: menu, misses: 0)
      }
      return await reply(t.menu(menu), "no-match")
    case .confirming(let c, let snapshot, let misses):
      guard Chooser.isYes(text, lang) else { return await miss(snapshot, misses) }
      guard await pin(c) else { return await miss(snapshot, misses, fresh: true) }
      await runs.update(run) {
        $0.justChosen = false
        $0.mayReturn = false
      }
      return await reply(t.chosen(c.spoken, prompt: state.prompt), "chosen", bot: c)
    case .choosing(let snapshot, let misses):
      if Conversation.norm(text).isEmpty { return await miss(snapshot, misses) }
      switch Chooser.match(text, snapshot, lang) {
      case .exact(let i):
        let c = snapshot[i]
        guard await pin(c) else { return await miss(snapshot, misses, fresh: true) }
        await runs.update(run) { $0.justChosen = true }
        return await reply(t.chosen(c.spoken, prompt: state.prompt), "chosen", bot: c)
      case .fuzzy(let i):
        let c = snapshot[i]
        await runs.update(run) { $0.phase = .confirming(c, snapshot: snapshot, misses: misses) }
        return await reply(t.confirm(c.spoken), "confirm", bot: c)
      case .none:
        return await miss(snapshot, misses)
      }
    }
  }
}

/// JavaScript's `s.slice(0, n)` on UTF-16 units, never splitting a surrogate pair.
func jsSlice(_ s: String, _ n: Int) -> String {
  var k = min(n, s.utf16.count)
  while k > 0 {
    if let r = String(s.utf16.prefix(k)) { return r }
    k -= 1
  }
  return ""
}
