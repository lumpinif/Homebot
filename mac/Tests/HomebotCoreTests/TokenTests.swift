// Ported from test/tokens-credentials.test.ts (token part) plus the bot-set rules of
// DESIGN §20.5 T1–T6 that are new in the Swift version.
import Foundation
import Testing

@testable import HomebotCore

func grant(_ key: String, _ sid: String = "1") -> BotGrant { BotGrant(key: key, sessionId: sid) }

func tokenStore(now: @escaping @Sendable () -> Double = { 1_000 }, artifacts: Bool = false) async throws -> TokenStore {
  let dir = try tmpDir()
  let s = TokenStore(file: dir.appendingPathComponent("tokens.json"), artifactsDir: artifacts ? dir.appendingPathComponent("Shortcuts") : nil, now: now)
  try await s.load()
  return s
}

/// A clock tests can move.
final class Clock: @unchecked Sendable {
  private let lock = NSLock()
  private var t: Double
  init(_ t: Double = 1_000) { self.t = t }
  var now: Double {
    get { lock.withLock { t } }
    set { lock.withLock { t = newValue } }
  }
  var fn: @Sendable () -> Double { { self.now } }
}

extension TokenStore {
  func state(_ id: String) -> TokenState? { records.first { $0.id == id }?.state }
  func usedAt(_ id: String) -> Double? { records.first { $0.id == id }?.usedAt }
}

/// The Shortcut is installed and has answered once: a use, then the takeover (T5).
func answered(_ s: TokenStore, _ t: (id: String, token: String), bot: String? = nil) async throws {
  #expect(try await s.verify(t.token, bot: bot).isOK)
  #expect(try await s.takeOver(t.id))
}

@Suite("Tokens")
struct TokenTests {
  @Test("issued plaintext is never stored, only its hash; listings carry no hash")
  func plaintext() async throws {
    let s = try await tokenStore()
    let t = try await s.issue(bots: [grant("chai")], label: "问拆解师")
    let raw = try String(contentsOf: s.file, encoding: .utf8)
    #expect(!raw.contains(t.token))
    let enc = JSONEncoder()
    #expect(!String(decoding: try enc.encode(await s.list()), as: UTF8.self).contains("hash"))
    #expect(modeOf(s.file) == 0o600)
  }

  @Test("verify accepts its bot or an omitted bot, refuses others and garbage")
  func verify() async throws {
    let s = try await tokenStore()
    let t = try await s.issue(bots: [grant("chai")], label: "a")
    #expect(try await s.verify(t.token, bot: "chai").isOK)
    #expect(try await s.verify(t.token).isOK)
    #expect(try await s.verify(t.token, bot: "other") == .forbidden)
    #expect(try await s.verify("nope", bot: "chai") == .invalid)
    #expect(try await s.verify(nil, bot: "chai") == .invalid)
  }

  @Test("replacement keeps the old token working until the new one has answered once (DECISIONS 27)")
  func replacement() async throws {
    let s = try await tokenStore()
    let old = try await s.issue(bots: [grant("chai")], label: "v1")
    try await answered(s, old, bot: "chai")
    let next = try await s.issue(bots: [grant("chai")], label: "v2", replaces: old.id)
    #expect(try await s.verify(old.token, bot: "chai").isOK, "old still valid while v2 is pending")
    #expect(try await s.verify(next.token, bot: "chai").isOK)
    #expect(await s.state(next.id) == .pending, "a use only marks it used")
    #expect(await s.usedAt(next.id) != nil, "a use only marks it used")
    #expect(try await s.verify(old.token, bot: "chai").isOK, "old still works after v2's first use")
    #expect(try await s.verify(next.token, bot: "chai").isOK, "v2 keeps serving until it answers")
    #expect(try await s.takeOver(next.id))
    #expect(try await s.verify(old.token, bot: "chai") == .invalid, "old retired after v2's first answer")
    #expect(try await s.takeOver(next.id) == false, "a second answer changes nothing")
    let reloaded = TokenStore(file: s.file)
    try await reloaded.load()
    #expect(await reloaded.state(old.id) == .retired)
  }

  @Test("an abandoned pending token never breaks the active one and expires")
  func abandoned() async throws {
    let clock = Clock()
    let s = try await tokenStore(now: clock.fn)
    let old = try await s.issue(bots: [grant("chai")], label: "v1")
    try await answered(s, old)
    let abandoned = try await s.issue(bots: [grant("chai")], label: "v2", replaces: old.id)
    clock.now += TokenStore.pendingTTLms
    #expect(try await s.verify(abandoned.token) == .invalid)
    #expect(try await s.expirePending() == [abandoned.id])
    #expect(try await s.verify(old.token).isOK)
  }

  @Test("revoke")
  func revoke() async throws {
    let s = try await tokenStore()
    let a = try await s.issue(bots: [grant("chai")], label: "a")
    #expect(try await s.revoke(a.id))
    #expect(try await s.verify(a.token) == .invalid)
    #expect(try await s.revoke("missing") == false)
  }

  @Test("B1: two stores on one file (gateway + CLI) always agree")
  func twoStores() async throws {
    let file = try tmpDir().appendingPathComponent("tokens.json")
    let gateway = TokenStore(file: file)
    let cli = TokenStore(file: file)
    try await gateway.load()
    try await cli.load()
    let a = try await cli.issue(bots: [grant("chai")], label: "a")
    #expect(try await gateway.verify(a.token, bot: "chai").isOK, "gateway sees new tokens")
    #expect(try await cli.revoke(a.id))
    #expect(try await gateway.verify(a.token, bot: "chai") == .invalid, "revocation reaches the gateway")
  }

  @Test("B1: activation in a stale store never overwrites a newer revoke")
  func staleActivation() async throws {
    let file = try tmpDir().appendingPathComponent("tokens.json")
    let cli = TokenStore(file: file)
    try await cli.load()
    let keep = try await cli.issue(bots: [grant("chai")], label: "keep")
    let kill = try await cli.issue(bots: [grant("chai")], label: "kill")
    let gateway = TokenStore(file: file)
    try await gateway.load() // snapshot with both pending
    try await cli.revoke(kill.id)
    #expect(try await gateway.verify(keep.token).isOK) // marking used = locked read-modify-write
    #expect(try await gateway.takeOver(keep.id)) // so is the takeover
    let fresh = TokenStore(file: file)
    try await fresh.load()
    #expect(await fresh.state(kill.id) == .retired)
    #expect(await fresh.state(keep.id) == .active)
  }

  @Test("B1: concurrent mutations from two stores are all kept")
  func concurrent() async throws {
    let file = try tmpDir().appendingPathComponent("tokens.json")
    let s1 = TokenStore(file: file)
    let s2 = TokenStore(file: file)
    try await s1.load()
    try await s2.load()
    try await withThrowingTaskGroup(of: Void.self) { g in
      for i in 0..<5 {
        g.addTask { _ = try await s1.issue(bots: [grant("a")], label: "x\(i)") }
        g.addTask { _ = try await s2.issue(bots: [grant("b")], label: "y\(i)") }
      }
      try await g.waitForAll()
    }
    let fresh = TokenStore(file: file)
    try await fresh.load()
    #expect(await fresh.records.count == 10)
  }

  @Test("S1: a Shortcut's phrase is unique under the issuance lock, across stores and kinds")
  func uniquePhrase() async throws {
    let file = try tmpDir().appendingPathComponent("tokens.json")
    let s1 = TokenStore(file: file)
    let s2 = TokenStore(file: file)
    try await s1.load()
    try await s2.load()
    async let a: Bool = (try? await s1.issue(bots: [grant("a")], label: "家庭助手", uniqueLabel: true)) != nil
    async let b: Bool = (try? await s2.issue(bots: [grant("b")], label: "家庭助手", kind: .lab, uniqueLabel: true)) != nil
    let results = await [a, b]
    #expect(results.filter { $0 }.count == 1, "two concurrent builds never share a phrase")
    let won = TokenStore(file: file)
    try await won.load()
    let first = try #require(await won.records.first)
    _ = try await won.issue(bots: [grant("a")], label: " House  BUTLER ", uniqueLabel: true)
    let clash = await errorText { _ = try await won.issue(bots: [grant("a")], label: "house butler", uniqueLabel: true) }
    #expect(clash?.contains("already uses") == true)
    let again = try await won.issue(bots: first.bots, label: "家庭助手", replaces: first.id, kind: first.effectiveKind, uniqueLabel: true)
    #expect(!again.id.isEmpty, "a replacement keeps its predecessor's phrase")
    try await won.revoke(first.id)
    try await won.revoke(again.id)
    _ = try await won.issue(bots: [grant("a")], label: "家庭助手", uniqueLabel: true) // retired tokens free their phrase
  }

  @Test("S5: token artifacts are removed on use, revoke, expiry, or after 24 h")
  func artifacts() async throws {
    let clock = Clock()
    let s = try await tokenStore(now: clock.fn, artifacts: true)
    let art = try #require(s.artifactsDir)
    try FileUtil.ensurePrivateDir(art)
    let used = try await s.issue(bots: [grant("chai")], label: "used")
    let revoked = try await s.issue(bots: [grant("chai")], label: "revoked")
    let idle = try await s.issue(bots: [grant("chai")], label: "idle")
    for x in [used, revoked, idle] { try FileUtil.writePrivateFile(try s.artifactPath(x.id, ext: "token"), "synthetic") }
    try FileUtil.writePrivateFile(art.appendingPathComponent("ffffffffffff.token"), "orphan")
    _ = try await s.verify(used.token)
    try await s.revoke(revoked.id)
    #expect(try FileManager.default.contentsOfDirectory(atPath: art.path).sorted() == ["\(idle.id).token"])
    clock.now = Date().timeIntervalSince1970 * 1000 + 25 * 3600 * 1000 // pending, but the artifact is older than 24 h
    try await s.cleanupArtifacts()
    #expect(try FileManager.default.contentsOfDirectory(atPath: art.path) == [])
  }

  @Test("M2 S1: cleanup in a stale store never deletes an artifact another process just built")
  func staleCleanup() async throws {
    let dir = try tmpDir()
    let art = dir.appendingPathComponent("Shortcuts")
    try FileUtil.ensurePrivateDir(art)
    let file = dir.appendingPathComponent("tokens.json")
    let gateway = TokenStore(file: file, artifactsDir: art)
    let cli = TokenStore(file: file, artifactsDir: art)
    try await gateway.load()
    try await cli.load()
    let built = try await cli.issue(bots: [grant("chai")], label: "Ask Chai")
    try FileUtil.writePrivateFile(try cli.artifactDir(built.id).appendingPathComponent("Ask Chai.shortcut"), "synthetic")
    #expect(try await gateway.cleanupArtifacts() == [], "decided against the current file, not the snapshot")
    let other = try await gateway.issue(bots: [grant("chai")], label: "x") // the mutation path sweeps too
    try await gateway.revoke(other.id)
    #expect(try FileManager.default.contentsOfDirectory(atPath: art.path) == [built.id])
  }

  @Test("M2 S1: concurrent builds and sweeps from two stores keep every live artifact")
  func concurrentSweeps() async throws {
    let dir = try tmpDir()
    let art = dir.appendingPathComponent("Shortcuts")
    try FileUtil.ensurePrivateDir(art)
    let file = dir.appendingPathComponent("tokens.json")
    let a = TokenStore(file: file, artifactsDir: art)
    let b = TokenStore(file: file, artifactsDir: art)
    try await a.load()
    try await b.load()
    let files = try await withThrowingTaskGroup(of: String?.self) { g in
      for _ in 0..<6 { g.addTask { _ = try await a.cleanupArtifacts(); return nil } }
      for i in 0..<6 {
        let s = i % 2 == 1 ? a : b
        g.addTask {
          let (id, _) = try await s.issue(bots: [grant("chai")], label: "t\(i)")
          try FileUtil.writePrivateFile(try s.artifactPath(id, ext: "token"), "synthetic")
          return "\(id).token"
        }
      }
      var out: [String] = []
      for try await f in g { if let f { out.append(f) } }
      return out
    }
    try await a.cleanupArtifacts()
    #expect(try FileManager.default.contentsOfDirectory(atPath: art.path).sorted() == files.sorted())
  }

  @Test("M2 S4 / T6: replaces must name a usable token of the same kind whose set is covered")
  func replacesRules() async throws {
    let s = try await tokenStore()
    let a = try await s.issue(bots: [grant("a")], label: "a")
    _ = try await s.verify(a.token)
    let cross = await errorText { _ = try await s.issue(bots: [grant("b")], label: "b", replaces: a.id) }
    #expect(cross?.contains("answers for bot \"a\"") == true)
    let missing = await errorText { _ = try await s.issue(bots: [grant("a")], label: "x", replaces: "000000000000") }
    #expect(missing?.contains("no such usable token") == true)
    try await s.revoke(a.id)
    let retired = await errorText { _ = try await s.issue(bots: [grant("a")], label: "x", replaces: a.id) }
    #expect(retired?.contains("no such usable token") == true)
    #expect(await s.records.count == 1, "rejected replacements issue nothing")
    let c = try await s.issue(bots: [grant("c")], label: "c")
    _ = try await s.verify(c.token)
    await #expect(throws: TokenError.self) { _ = try await s.issue(bots: [grant("b")], label: "b", replaces: c.id) }
    #expect(try await s.verify(c.token).isOK, "a rejected cross-bot replacement leaves the old token usable")
    // A different session of the same key is a different grant.
    await #expect(throws: TokenError.self) { _ = try await s.issue(bots: [grant("c", "2")], label: "c2", replaces: c.id) }
  }

  @Test("S2: a wait-test token never works for /v1/ask, and using it leaves the voice token alone")
  func kinds() async throws {
    let s = try await tokenStore()
    let voice = try await s.issue(bots: [grant("homebot")], label: "voice")
    #expect(try await s.verify(voice.token, bot: "homebot").isOK)
    let crossKind = await errorText { _ = try await s.issue(bots: [grant("homebot")], label: "probe", replaces: voice.id, kind: .probe) }
    #expect(crossKind?.contains("never replace each other") == true)
    let probe = try await s.issue(bots: [grant("homebot")], label: "probe", kind: .probe)
    #expect(try await s.verify(probe.token, bot: "homebot") == .invalid, "not a voice token")
    #expect(await s.state(probe.id) == .pending, "a refused use does not activate it")
    #expect(try await s.verify(probe.token, bot: "homebot", kind: .probe).isOK)
    #expect(try await s.verify(voice.token, bot: "homebot", kind: .probe) == .invalid)
    #expect(try await s.verify(voice.token, bot: "homebot").isOK, "the voice Shortcut still works")
    await #expect(throws: TokenError.self) { _ = try await s.issue(bots: [grant("homebot")], label: "v2", replaces: probe.id) }
  }
}

@Suite("Tokens: bot sets (DESIGN §20.5 T1–T6)")
struct BotSetTests {
  @Test("T1: a set is non-empty, at most 9 bots, no bot twice")
  func setLimits() async throws {
    let s = try await tokenStore()
    await #expect(throws: TokenError.self) { _ = try await s.issue(bots: [], label: "x") }
    await #expect(throws: TokenError.self) { _ = try await s.issue(bots: (0..<10).map { grant("b\($0)", "\($0)") }, label: "x") }
    await #expect(throws: TokenError.self) { _ = try await s.issue(bots: [grant("a"), grant("a", "2")], label: "x") }
    _ = try await s.issue(bots: (0..<9).map { grant("b\($0)", "\($0)") }, label: "nine")
  }

  @Test("T3: a multi-bot token needs a named bot; an unnamed request pins only a one-bot set")
  func multiBot() async throws {
    let s = try await tokenStore()
    let t = try await s.issue(bots: [grant("a", "1"), grant("b", "2")], label: "entry", mode: .entry)
    #expect(try await s.verify(t.token, bot: "b") == .ok(try #require(await s.records.first), bot: grant("b", "2")))
    guard case .ok(_, let pinned) = try await s.verify(t.token) else { Issue.record("expected ok"); return }
    #expect(pinned == nil, "the entry flow chooses; nothing is pinned")
    #expect(try await s.verify(t.token, bot: "c") == .forbidden)
  }

  @Test("T3: a grant whose session is no longer the bot's current one is dead (401)")
  func sessionMismatch() async throws {
    let s = try await tokenStore()
    let t = try await s.issue(bots: [grant("a", "1"), grant("b", "2")], label: "x")
    let current: @Sendable (String) -> String? = { ["a": "1", "b": "99"][$0] }
    #expect(try await s.verify(t.token, bot: "a", sessionOf: current).isOK)
    #expect(try await s.verify(t.token, bot: "b", sessionOf: current) == .invalid)
    let allDead: @Sendable (String) -> String? = { _ in nil }
    #expect(try await s.verify(t.token, sessionOf: allDead) == .invalid, "no live grant left")
  }

  @Test("T5: a use marks a token only when a bot is named or pinned; only the takeover activates")
  func activation() async throws {
    let s = try await tokenStore()
    let old = try await s.issue(bots: [grant("a", "1"), grant("b", "2")], label: "v1")
    try await answered(s, old, bot: "a")
    let t = try await s.issue(bots: [grant("a", "1"), grant("b", "2")], label: "v2", replaces: old.id)
    _ = try await s.verify(t.token) // only authenticates: the entry flow's choosing step
    #expect(await s.state(t.id) == .pending)
    _ = try await s.verify(t.token, bot: "a", use: false)
    #expect(await s.state(t.id) == .pending)
    #expect(await s.usedAt(t.id) == nil)
    #expect(try await s.verify(t.token, bot: "zzz") == .forbidden)
    #expect(try await s.verify(t.token, bot: "a", sessionOf: { _ in "9" }) == .invalid)
    #expect(await s.state(t.id) == .pending)
    #expect(await s.state(old.id) == .active, "a refused use never retires the predecessor")
    #expect(await s.usedAt(t.id) == nil, "a refused use does not mark it used")
    _ = try await s.verify(t.token, bot: "a")
    #expect(await s.state(t.id) == .pending)
    #expect(await s.usedAt(t.id) != nil)
    #expect(await s.state(old.id) == .active, "a use without an answer never retires the predecessor")
    #expect(try await s.takeOver(t.id))
    #expect(await s.state(t.id) == .active)
    #expect(await s.state(old.id) == .retired)
  }

  @Test("T5 (DECISIONS 27): a copy that replaces nothing never retires anything, even when it answers")
  func copyRetiresNothing() async throws {
    let s = try await tokenStore()
    let a = try await s.issue(bots: [grant("a", "1")], label: "first iPhone")
    try await answered(s, a)
    let copy = try await s.issue(bots: [grant("a", "1")], label: "second iPhone")
    try await answered(s, copy)
    #expect(await s.state(a.id) == .active)
    #expect(await s.state(copy.id) == .active)
  }

  @Test("T5 (DECISIONS 27): a chain's newest replacement answering first retires every Shortcut it covers")
  func chainTakeover() async throws {
    let s = try await tokenStore()
    let a = try await s.issue(bots: [grant("a", "1")], label: "v1")
    try await answered(s, a)
    let b = try await s.issue(bots: [grant("a", "1")], label: "v2", replaces: a.id)
    _ = try await s.verify(b.token) // on a phone, never answered
    let c = try await s.issue(bots: [grant("a", "1")], label: "v3", replaces: b.id)
    try await answered(s, c)
    #expect(await s.state(a.id) == .retired)
    #expect(await s.state(b.id) == .retired)
    #expect(await s.state(c.id) == .active)
    #expect(try await s.takeOver(b.id) == false, "a retired replacement never comes back")
  }

  @Test("T5 (DECISIONS 27): a used replacement outlives the pending window; an unused one expires")
  func usedOutlivesWindow() async throws {
    let clock = Clock()
    let s = try await tokenStore(now: clock.fn)
    let old = try await s.issue(bots: [grant("a", "1")], label: "v1")
    try await answered(s, old)
    let used = try await s.issue(bots: [grant("a", "1")], label: "v2", replaces: old.id)
    _ = try await s.verify(used.token)
    let unused = try await s.issue(bots: [grant("a", "1")], label: "v3")
    clock.now += TokenStore.pendingTTLms
    #expect(try await s.verify(used.token).isOK, "on a phone, waiting for its first answer")
    #expect(try await s.verify(unused.token) == .invalid)
    #expect(try await s.verify(old.token).isOK)
    // A restart's cleanup keeps it too (only never-used tokens expire), and its answer still takes over.
    #expect(try await s.expirePending() == [unused.id])
    #expect(try await s.verify(used.token).isOK)
    #expect(try await s.takeOver(used.id))
    #expect(try await s.verify(old.token) == .invalid)
  }

  @Test("T5 (DECISIONS 27): no takeover when the client left or the answering grant is gone")
  func takeoverRechecks() async throws {
    let s = try await tokenStore()
    let old = try await s.issue(bots: [grant("a", "1"), grant("b", "1")], label: "v1")
    try await answered(s, old)
    let next = try await s.issue(bots: [grant("a", "1"), grant("b", "1")], label: "v2", replaces: old.id)
    _ = try await s.verify(next.token, bot: "a")
    #expect(try await s.takeOver(next.id, grant: grant("a"), while: { false }) == false, "the client left: its answer was never spoken")
    #expect(try await s.takeOver(next.id, grant: grant("a", "2")) == false, "the bot has another session now")
    // Bot "a" is removed from both (old first: a replacement never drops a bot of its predecessor).
    try await s.setBots(old.id, [grant("b", "1")])
    try await s.setBots(next.id, [grant("b", "1")])
    #expect(try await s.takeOver(next.id, grant: grant("a")) == false, "the answering bot was removed from it")
    #expect(try await s.verify(old.token).isOK)
    #expect(try await s.takeOver(next.id, grant: grant("b")))
    #expect(try await s.verify(old.token) == .invalid)
  }

  @Test("T5 (DECISIONS 27): concurrent answers and uses on old and new tokens retire the old one once and keep one active")
  func concurrentTakeover() async throws {
    let file = try tmpDir().appendingPathComponent("tokens.json")
    let gw = TokenStore(file: file)
    let cli = TokenStore(file: file)
    try await gw.load()
    try await cli.load()
    let old = try await gw.issue(bots: [grant("a", "1")], label: "v1")
    try await answered(gw, old)
    let b = try await gw.issue(bots: [grant("a", "1")], label: "v2", replaces: old.id)
    let c = try await gw.issue(bots: [grant("a", "1")], label: "v3", replaces: old.id)
    for _ in 0..<5 {
      try await withThrowingTaskGroup(of: Void.self) { g in
        g.addTask { _ = try await gw.verify(old.token) }
        g.addTask { _ = try await cli.verify(b.token) }
        g.addTask { _ = try await gw.takeOver(b.id) }
        g.addTask { _ = try await cli.takeOver(b.id) }
        g.addTask { _ = try await gw.takeOver(c.id) }
        g.addTask { _ = try await cli.verify(old.token) }
        try await g.waitForAll()
      }
    }
    let fresh = TokenStore(file: file)
    try await fresh.load()
    #expect(await fresh.state(old.id) == .retired)
    #expect(await fresh.state(b.id) == .active, "two replacements of one Shortcut both answered: both work")
    #expect(await fresh.state(c.id) == .active, "two replacements of one Shortcut both answered: both work")
    let retiredAt = await fresh.records.first { $0.id == old.id }?.retiredAt
    #expect(retiredAt != nil)
    #expect(await fresh.records.count == 3, "no write was lost")
  }

  @Test("T5: the predecessor is not retired if the new set no longer covers it")
  func activationSubset() async throws {
    let file = try tmpDir().appendingPathComponent("tokens.json")
    let s = TokenStore(file: file)
    try await s.load()
    let old = try await s.issue(bots: [grant("a", "1")], label: "v1")
    try await answered(s, old)
    let next = try await s.issue(bots: [grant("a", "1")], label: "v2", replaces: old.id)
    // Another process widens the old token behind the issuing store's back (bypassing T4's
    // mirroring), so only the activation-time check is left to protect bot b.
    var recs = try #require(try FileUtil.readJSON(TokenFile.self, from: file)).tokens
    recs[recs.firstIndex { $0.id == old.id }!].bots.append(grant("b", "2"))
    try FileUtil.writeJSON(file, TokenFile(tokens: recs))
    try await answered(s, next, bot: "a")
    #expect(await s.state(next.id) == .active)
    #expect(await s.state(old.id) == .active, "nothing silently lost: both stay usable")
  }

  @Test("T4: editing a set changes no state; an edit is mirrored into a pending replacement")
  func editMirrors() async throws {
    let s = try await tokenStore()
    let old = try await s.issue(bots: [grant("a", "1")], label: "v1")
    try await answered(s, old)
    let next = try await s.issue(bots: [grant("a", "1")], label: "v2", replaces: old.id)
    try await s.setBots(old.id, [grant("a", "1"), grant("b", "2")])
    #expect(await s.state(old.id) == .active)
    #expect(await s.state(next.id) == .pending)
    #expect(await s.records.first { $0.id == next.id }?.bots == [grant("a", "1"), grant("b", "2")], "the replacement keeps covering its predecessor")
    let drop = await errorText { try await s.setBots(next.id, [grant("a", "1")]) }
    #expect(drop?.contains("drop it there first") == true)
    try await answered(s, next, bot: "b")
    #expect(await s.state(old.id) == .retired)
    await #expect(throws: TokenError.self) { try await s.setBots(next.id, []) }
    await #expect(throws: TokenError.self) { try await s.setBots(old.id, [grant("a", "1")]) } // retired
  }

  @Test("T4: an edit reaches every pending replacement down a chain (Codex S4 review 4)")
  func editMirrorsChain() async throws {
    let s = try await tokenStore()
    let a = try await s.issue(bots: [grant("home", "1"), grant("finance", "2")], label: "v1")
    _ = try await s.verify(a.token, bot: "home")
    let b = try await s.issue(bots: [grant("home", "1"), grant("finance", "2")], label: "v2", replaces: a.id)
    let c = try await s.issue(bots: [grant("home", "1"), grant("finance", "2")], label: "v3", replaces: b.id)
    try await s.setBots(a.id, [grant("home", "1")])
    #expect(await s.records.first { $0.id == c.id }?.bots == [grant("home", "1")], "the removed access is gone at the end of the chain too")
    #expect(try await s.verify(c.token, bot: "finance") == .forbidden)
    try await s.setBots(a.id, [grant("home", "1"), grant("tv", "3")])
    #expect(await s.records.first { $0.id == c.id }?.bots == [grant("home", "1"), grant("tv", "3")])
  }

  @Test("T3/T5: a pin for a session the grant no longer has marks and retires nothing (Codex S4 review 3)")
  func pinSession() async throws {
    let s = try await tokenStore()
    let old = try await s.issue(bots: [grant("a", "1")], label: "v1")
    try await answered(s, old)
    let next = try await s.issue(bots: [grant("a", "2"), grant("b", "3")], label: "v2", replaces: nil)
    #expect(try await s.verify(next.token, bot: "a", session: "1") == .invalid, "the menu said session 1; the grant is session 2 now")
    #expect(await s.state(next.id) == .pending)
    #expect(await s.usedAt(next.id) == nil)
    #expect(await s.state(old.id) == .active)
    guard case .ok(_, let g) = try await s.verify(next.token, bot: "a", session: "2") else { Issue.record("not admitted"); return }
    #expect(g == grant("a", "2"))
    #expect(await s.state(next.id) == .pending, "the pin marks it used; the takeover waits for an answer")
    #expect(await s.usedAt(next.id) != nil, "the pin marks it used; the takeover waits for an answer")
  }

  @Test("T4: a dropped bot is dropped from a pending replacement too (Codex S1 review 2)")
  func editMirrorsRemoval() async throws {
    let s = try await tokenStore()
    let old = try await s.issue(bots: [grant("home", "1"), grant("finance", "2")], label: "v1")
    _ = try await s.verify(old.token, bot: "home")
    let next = try await s.issue(bots: [grant("home", "1"), grant("finance", "2")], label: "v2", replaces: old.id)
    try await s.setBots(old.id, [grant("home", "1")])
    #expect(await s.records.first { $0.id == next.id }?.bots == [grant("home", "1")])
    #expect(try await s.verify(next.token, bot: "finance") == .forbidden, "the removed access does not come back")
  }

  @Test("a refused edit leaves the cache and the file untouched (Codex S1 review 1)")
  func refusedEditRollsBack() async throws {
    let s = try await tokenStore()
    let a = try await s.issue(bots: [grant("a", "1")], label: "a")
    try await answered(s, a)
    let b = try await s.issue(bots: [grant("a", "1")], label: "b", replaces: a.id)
    _ = try await s.issue(bots: [grant("a", "1")] + (1...8).map { grant("c\($0)", "1\($0)") }, label: "c", replaces: a.id)
    let tenth = grant("z", "99")
    await #expect(throws: TokenError.self) { try await s.setBots(a.id, [grant("a", "1"), tenth]) } // c would exceed 9
    #expect(await s.records.first { $0.id == b.id }?.bots == [grant("a", "1")], "no half-applied mirror in memory")
    #expect(try await s.verify(b.token, bot: "z") == .forbidden)
    #expect(await s.state(a.id) == .active)
  }

  @Test("an expired pending token is not a usable predecessor (Codex S1 review 13)")
  func expiredPredecessor() async throws {
    let clock = Clock()
    let s = try await tokenStore(now: clock.fn)
    let p = try await s.issue(bots: [grant("a", "1")], label: "p")
    clock.now += TokenStore.pendingTTLms
    let e = await errorText { _ = try await s.issue(bots: [grant("a", "1")], label: "q", replaces: p.id) }
    #expect(e?.contains("no such usable token") == true)
    await #expect(throws: TokenError.self) { try await s.setBots(p.id, [grant("a", "1"), grant("b", "2")]) }
  }

  @Test("T6: removing a bot drops its grant everywhere and retires tokens left empty")
  func revokeBot() async throws {
    let s = try await tokenStore()
    let solo = try await s.issue(bots: [grant("a", "1")], label: "solo")
    let pair = try await s.issue(bots: [grant("a", "1"), grant("b", "2")], label: "pair")
    let other = try await s.issue(bots: [grant("b", "2")], label: "other")
    let r = try await s.revokeBot("a")
    #expect(r.retired == [solo.id])
    #expect(r.narrowed == [pair.id])
    #expect(await s.records.first { $0.id == pair.id }?.bots == [grant("b", "2")])
    #expect(await s.state(other.id) == .pending)
    #expect(try await s.verify(pair.token, bot: "a") == .forbidden)
  }

  @Test("rule 3: grants() checks the exact (key, session) pair of a usable token")
  func grants() async throws {
    let s = try await tokenStore()
    let t = try await s.issue(bots: [grant("a", "1")], label: "x")
    #expect(try await s.grants(t.id, grant("a", "1")))
    #expect(try await s.grants(t.id, grant("a", "2")) == false)
    try await s.revoke(t.id)
    #expect(try await s.grants(t.id, grant("a", "1")) == false)
  }

  @Test("kind and mode are separate: an entry Shortcut can replace a per-bot one")
  func modeVsKind() async throws {
    let s = try await tokenStore()
    let single = try await s.issue(bots: [grant("a", "1")], label: "x", mode: .single)
    let entry = try await s.issue(bots: [grant("a", "1"), grant("b", "2")], label: "y", replaces: single.id, mode: .entry)
    #expect(await s.list().first { $0.id == entry.id }?.mode == .entry)
    #expect(await s.records.first { $0.id == entry.id }?.kind == nil, "voice tokens store no kind, as in the TypeScript file")
  }
}

@Suite("Tokens: migration from the TypeScript version (T2)")
struct MigrationTests {
  let hash = String(repeating: "ab", count: 32)

  func json(_ extra: [String: Any] = [:]) -> [String: Any] {
    var j: [String: Any] = ["id": "0123456789ab", "hash": hash, "bot": "chai", "label": "家庭助手", "state": "active", "createdAt": 5, "activatedAt": 6, "siriLang": "zh-CN", "sessionId": "100"]
    for (k, v) in extra { j[k] = v }
    return j
  }

  @Test("a record with a session becomes a one-bot legacy set; everything else is kept")
  func withSession() throws {
    let r = try #require(migrateTypeScriptToken(json(), sessionOf: { _ in "999" }, now: 50))
    #expect(r.bots == [grant("chai", "100")], "the stored session wins over the current one")
    #expect(r.hash == hash && r.id == "0123456789ab" && r.label == "家庭助手" && r.state == .active)
    #expect(r.createdAt == 5 && r.activatedAt == 6 && r.siriLang == "zh-CN" && r.kind == nil)
    #expect(r.mode == .legacy)
    let probe = try #require(migrateTypeScriptToken(json(["kind": "probe"]), sessionOf: { _ in "100" }, now: 50))
    #expect(probe.kind == .probe)
  }

  @Test("a sessionless record is retired unless the user binds it")
  func sessionless() throws {
    var j = json()
    j["sessionId"] = nil
    let retired = try #require(migrateTypeScriptToken(j, sessionOf: { _ in "100" }, now: 50))
    #expect(retired.state == .retired)
    #expect(retired.retiredAt == 50)
    let bound = try #require(migrateTypeScriptToken(j, sessionOf: { _ in "100" }, now: 50, bindSessionless: true))
    #expect(bound.state == .active)
    #expect(bound.bots == [grant("chai", "100")])
  }

  @Test("a record whose bot is gone is retired; malformed records are skipped")
  func goneOrMalformed() throws {
    let gone = try #require(migrateTypeScriptToken(json(), sessionOf: { _ in nil }, now: 50))
    #expect(gone.state == .retired)
    #expect(migrateTypeScriptToken(json(["kind": "weird"]), sessionOf: { _ in "1" }, now: 1) == nil)
    #expect(migrateTypeScriptToken(json(["id": "../x"]), sessionOf: { _ in "1" }, now: 1) == nil)
    #expect(migrateTypeScriptToken(json(["hash": "short"]), sessionOf: { _ in "1" }, now: 1) == nil)
  }
}
