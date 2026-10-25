// Runs of a looping Shortcut (DESIGN §18.2): one invocation = one run; each listen-and-POST inside
// it is a step. The gateway issues the run id, so two overlapping invocations of the same
// Shortcut never share state. Steps are ordered; a repeated step (an HTTP retry) with the same
// input gets the same response and never runs its work twice; a repeat with different input is
// refused, so a new question is never paired with an old answer (DESIGN §20.5 rule 4). A run that ended stays known until it expires, so a
// retry of its last step still gets the final response while any later step is refused.
// Memory only: a restart forgets every run. Ported from src/core/runs.ts.
import CryptoKit
import Foundation

/// The answer to every step of a looping Shortcut. V1: Speak Text `say`, then Ask for Input with
/// `ask`. V2: Ask for Input with `say` as the question. The Shortcut stops after speaking `say`
/// unless `next` is "listen".
public struct LoopResponse: Sendable, Equatable, Codable {
  public enum Mode: String, Sendable, Codable { case v1, v2 }
  public enum Next: String, Sendable, Codable { case listen, end }

  public var say: String
  public var ask: String
  public var mode: Mode
  public var next: Next
  public var run: String

  public init(say: String, ask: String, mode: Mode, next: Next, run: String) {
    self.say = say
    self.ask = ask
    self.mode = mode
    self.next = next
    self.run = run
  }
}

public enum StepCheck<S: Sendable, R: Sendable>: Sendable {
  case next(S)
  case `repeat`(Task<R, Never>, S)
  /// The last step's number again, but with different input: not a retry.
  case changed
  /// The run ended: nothing after its last step is taken.
  case ended
  /// The previous step's response is not ready yet: nothing is taken.
  case early
  case unknown

  public var kind: String {
    switch self {
    case .next: "next"
    case .repeat: "repeat"
    case .changed: "changed"
    case .ended: "ended"
    case .early: "early"
    case .unknown: "unknown"
    }
  }
}

public struct RunError: Error, CustomStringConvertible {
  public var description: String { "step not checked" }
}

public actor RunStore<S: Sendable, R: Sendable> {
  public static var defaultTTLms: Double { 5 * 60_000 }

  struct Run {
    let tokenId: String
    /// The last step taken (0 = the run's start).
    var step: Int
    /// The response to `step`, shared by retries of that step.
    var response: Task<R, Never>
    /// Which response `settled` refers to.
    var generation: Int
    /// False while the response to `step` is still being made.
    var settled: Bool
    /// The run ended: no step after `step` is taken.
    var ended: Bool
    var expiresAt: Double
    var state: S
    /// SHA-256 of the input of `step` (memory only).
    var input: [UInt8]
  }

  var runs: [String: Run] = [:]
  let ttlMs: Double
  let now: @Sendable () -> Double

  public init(ttlMs: Double = RunStore.defaultTTLms, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
    self.ttlMs = ttlMs
    self.now = now
  }

  /// A run id as issued by `start`; anything else is never looked up or logged.
  public static func isRunId(_ v: String) -> Bool {
    v.utf8.count == 16 && v.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
  }

  func sweep() {
    let t = now()
    runs = runs.filter { $0.value.expiresAt > t }
  }

  /// The fingerprint of a step's input.
  public static func fingerprint(_ input: String) -> [UInt8] {
    Array(SHA256.hash(data: Data(input.utf8)))
  }

  /// The response is marked settled before its value is visible to anyone awaiting it.
  private func track(_ id: String, generation: Int, _ make: @escaping @Sendable () async -> R) -> Task<R, Never> {
    Task {
      let r = await make()
      self.settle(id, generation)
      return r
    }
  }

  private func settle(_ id: String, _ generation: Int) {
    if runs[id]?.generation == generation { runs[id]?.settled = true }
  }

  /// Start a run (step 0) for a token; `make` builds the start response from the run id.
  public func start(tokenId: String, state: S, make: @escaping @Sendable (String) async -> R) -> (id: String, response: Task<R, Never>) {
    sweep()
    let id = Random.hex(bytes: 8)
    let response = track(id, generation: 0) { await make(id) }
    runs[id] = Run(tokenId: tokenId, step: 0, response: response, generation: 0, settled: false, ended: false, expiresAt: now() + ttlMs, state: state, input: RunStore.fingerprint(""))
    return (id, response)
  }

  /// Classify a step: the next one (`run.step + 1`), a repeat of the last one, or anything else
  /// (unknown or expired run, another token's run, a skipped or old step). A next step is refused
  /// once the run ended, or while the last step's response is still being made.
  public func check(_ runId: String, tokenId: String, step: Int, input: String = "") -> StepCheck<S, R> {
    sweep()
    guard let r = runs[runId], r.tokenId == tokenId else { return .unknown }
    if step == r.step {
      return TokenStore.constantTimeEqual(r.input, RunStore.fingerprint(input)) ? .repeat(r.response, r.state) : .changed
    }
    if step == r.step + 1 {
      if r.ended { return .ended }
      if !r.settled { return .early }
      return .next(r.state)
    }
    return .unknown
  }

  /// Take step `step` (after `check` said "next"); `make` builds its response.
  public func take(_ runId: String, step: Int, input: String = "", make: @escaping @Sendable () async -> R) throws -> Task<R, Never> {
    guard var r = runs[runId], step == r.step + 1, !r.ended, r.settled else { throw RunError() }
    r.generation += 1
    let response = track(runId, generation: r.generation, make)
    r.step = step
    r.input = RunStore.fingerprint(input)
    r.response = response
    r.settled = false
    r.expiresAt = now() + ttlMs
    runs[runId] = r
    return response
  }

  public enum Claim: Sendable {
    case taken(Task<R, Never>)
    case refused(StepCheck<S, R>)
  }

  /// Check a step and, if it is the next one and `accept` agrees, take it in the same actor turn,
  /// so two concurrent copies of one step can't both be taken (the second sees a repeat).
  public func claim(_ runId: String, tokenId: String, step: Int, input: String = "", accept: (S) -> Bool, make: @escaping @Sendable (S) async -> R) -> Claim {
    let c = check(runId, tokenId: tokenId, step: step, input: input)
    guard case .next(let state) = c, accept(state) else { return .refused(c) }
    var r = runs[runId]!
    r.generation += 1
    let response = track(runId, generation: r.generation) { await make(state) }
    r.step = step
    r.input = RunStore.fingerprint(input)
    r.response = response
    r.settled = false
    r.expiresAt = now() + ttlMs
    runs[runId] = r
    return .taken(response)
  }

  /// Mark a run ended after its current step: retries of that step still get its response.
  public func finish(_ runId: String) {
    runs[runId]?.ended = true
  }

  /// Change a run's state (the conversation's turn count, its pinned bot).
  public func update(_ runId: String, _ fn: @Sendable (inout S) -> Void) {
    if runs[runId] != nil { fn(&runs[runId]!.state) }
  }

  public func state(_ runId: String) -> S? { runs[runId]?.state }

  /// The run's state only for the token that started it.
  public func state(_ runId: String, ownedBy tokenId: String) -> S? {
    guard let r = runs[runId], r.tokenId == tokenId else { return nil }
    return r.state
  }

  public var size: Int {
    sweep()
    return runs.count
  }
}
