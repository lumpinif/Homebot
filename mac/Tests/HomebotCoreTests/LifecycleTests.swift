// Ported from test/lifecycle.test.ts (M4 review B1/S1/S2: one owner for a bot's identity, its
// cursor and its tokens), plus T3's one-step admission.
import Foundation
import Testing

@testable import HomebotCore

struct Stores {
  let dir: URL
  let config: ConfigStore
  let state: StateStore
  let tokens: TokenStore
  var lifecycle: BotLifecycle { BotLifecycle(config: config, state: state, tokens: tokens) }

  /// Fresh store objects on the same files, as another process (CLI vs gateway) would have.
  static func open(_ dir: URL) async throws -> Stores {
    let s = Stores(dir: dir, config: ConfigStore(file: dir.appendingPathComponent("config.json")), state: StateStore(file: dir.appendingPathComponent("state.json")), tokens: TokenStore(file: dir.appendingPathComponent("tokens.json"), artifactsDir: dir.appendingPathComponent("Shortcuts")))
    try await s.config.load()
    try await s.state.load()
    try await s.tokens.load()
    return s
  }

  static func fresh() async throws -> Stores { try await open(try tmpDir()) }

  func usable(_ bot: String) async -> [TokenInfo] {
    await tokens.list().filter { $0.bots.contains { $0.key == bot } && $0.state != .retired }
  }
}

let botA = Bot(key: "homebot", name: "homebot", sessionId: "14752726", strictEcho: true)
let botB = Bot(key: "homebot", name: "homebot", sessionId: "555", strictEcho: true)

@Suite("Bot lifecycle")
struct LifecycleTests {
  @Test("aliases: the order is kept; blank, punctuation-only, repeated or too many names are refused (Codex S4 review 6)")
  func aliases() async throws {
    let s = try await Stores.fresh()
    try await s.lifecycle.add(botA, cursor: "1", maxSeq: "1")
    #expect(try await s.lifecycle.setAliases("homebot", ["格罗克", "Grok"]))
    #expect(await s.config.bot("homebot")?.aliases == ["格罗克", "Grok"])
    for bad in [["..."], ["  "], ["Grok", "grok!"], (0...Bot.maxAliases).map { "n\($0)" }] {
      await #expect(throws: StoreError.self, "\(bad)") { try await s.lifecycle.setAliases("homebot", bad) }
    }
    #expect(await s.config.bot("homebot")?.aliases == ["格罗克", "Grok"], "a refused change keeps the old names")
    #expect(try await s.lifecycle.setAliases("homebot", []))
    #expect(await s.config.bot("homebot")?.aliases == [])
    #expect(try await s.lifecycle.setAliases("nope", ["x"]) == false)
  }

  @Test("B1: a build that captured the bot before remove + re-add under the same key issues nothing")
  func capturedBuild() async throws {
    let s = try await Stores.fresh()
    try await s.lifecycle.add(botA, cursor: "10", maxSeq: "10")
    let captured = try #require(await s.config.bot("homebot")) // the build read the bot here...
    let other = try await Stores.open(s.dir)
    #expect(try await other.lifecycle.remove("homebot")?.retired == []) // ...then another process removed it
    try await other.lifecycle.add(botB, cursor: "20", maxSeq: "20") // ...and re-added the key for another conversation
    let profile = try Profile.make(botName: captured.name)
    let e = await errorText {
      _ = try await ShortcutMaker.make(tokens: s.tokens, lifecycle: s.lifecycle, bots: [captured], profile: profile, baseUrl: "http://mac.local:8787")
    }
    #expect(e?.contains("removed or changed meanwhile; nothing was issued") == true)
    try await s.tokens.load()
    #expect(await s.tokens.list().isEmpty, "no token exists for the old conversation")
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: s.dir.appendingPathComponent("Shortcuts").path)) ?? []).isEmpty, "no file was written")
  }

  @Test("B1: removal racing a build never leaves a usable token behind")
  func removalRace() async throws {
    for i in 0..<10 {
      let s = try await Stores.fresh()
      try await s.lifecycle.add(botA, cursor: "10", maxSeq: "10")
      let other = try await Stores.open(s.dir)
      let tokens = s.tokens
      async let built: Void = { _ = try? await s.lifecycle.issueFor([botA]) { bots in try await tokens.issue(bots: bots.map { BotGrant(key: $0.key, sessionId: $0.sessionId) }, label: "x") } }()
      async let removed: Void = { _ = try? await other.lifecycle.remove("homebot") }()
      _ = await (built, removed)
      try await s.tokens.load()
      #expect(await s.usable("homebot").isEmpty, "round \(i)")
    }
  }

  @Test("B1: tokens record the conversation; removal retires every token left empty")
  func removal() async throws {
    let s = try await Stores.fresh()
    try await s.lifecycle.add(botA, cursor: "10", maxSeq: "10")
    let tokens = s.tokens
    let issue: @Sendable ([Bot]) async throws -> (id: String, token: String) = { bots in
      try await tokens.issue(bots: bots.map { BotGrant(key: $0.key, sessionId: $0.sessionId) }, label: "x")
    }
    let t1 = try await s.lifecycle.issueFor([botA], issue)
    let t2 = try await s.lifecycle.issueFor([botA], issue)
    #expect(await s.tokens.list().first { $0.id == t1.id }?.bots == [BotGrant(key: "homebot", sessionId: botA.sessionId)])
    let r = try #require(try await s.lifecycle.remove("homebot"))
    #expect(r.retired.sorted() == [t1.id, t2.id].sorted())
    #expect(await s.config.bot("homebot") == nil)
    #expect(await s.state.cursor("homebot") == nil)
    #expect(try await s.tokens.verify(t1.token, bot: "homebot") == .invalid)
    #expect(try await s.lifecycle.remove("homebot") == nil, "unknown bot")
  }

  @Test("S1: a rejected concurrent add changes neither the config nor the other bot's cursor")
  func rejectedAdd() async throws {
    let s = try await Stores.fresh()
    let other = try await Stores.open(s.dir)
    // Both validated the key as free before their (slow) cold syncs; A finishes first.
    try await s.config.checkBot(botA)
    try await other.config.checkBot(botB)
    try await s.lifecycle.add(botA, cursor: "10", maxSeq: "10")
    let e = await errorText { try await other.lifecycle.add(botB, cursor: "99", maxSeq: "99") }
    #expect(e?.contains("already belongs to session 14752726") == true)
    let fresh = try await Stores.open(s.dir)
    #expect(await fresh.config.bot("homebot")?.sessionId == botA.sessionId)
    #expect(await fresh.state.cursor("homebot")?.cursor == "10")
    #expect(await fresh.state.cursor("homebot")?.sessionId == botA.sessionId)
  }

  @Test("S1: a cursor tagged for another conversation is never advanced by a stale writer")
  func staleCursor() async throws {
    let s = try await Stores.fresh()
    try await s.lifecycle.add(botB, cursor: "20", maxSeq: "20")
    try await s.state.setCursor("homebot", cursor: "500", maxSeq: "500", sessionId: botA.sessionId) // a late request for the old bot
    #expect(await s.state.cursor("homebot")?.cursor == "20")
    #expect(await s.state.cursor("homebot")?.sessionId == botB.sessionId)
    try await s.state.setCursor("homebot", cursor: "30", maxSeq: "30", sessionId: botB.sessionId)
    #expect(await s.state.cursor("homebot")?.cursor == "30")
  }

  @Test("T3: admit checks the current session under the config lock and returns the authorized grant")
  func admit() async throws {
    let s = try await Stores.fresh()
    try await s.lifecycle.add(botA, cursor: "10", maxSeq: "10")
    let tokens = s.tokens
    let t = try await s.lifecycle.issueFor([botA]) { bots in try await tokens.issue(bots: bots.map { BotGrant(key: $0.key, sessionId: $0.sessionId) }, label: "x") }
    guard case .ok(let rec, let g) = try await s.lifecycle.admit(t.token, bot: "homebot") else { Issue.record("expected ok"); return }
    #expect(g == BotGrant(key: "homebot", sessionId: botA.sessionId))
    #expect(rec.state == .pending && rec.usedAt != nil, "admit marks the token used; only an answer activates it (T5)")
    #expect(await s.lifecycle.stillGranted(t.id, BotGrant(key: "homebot", sessionId: botA.sessionId)))
    // Another process removes the bot and re-adds the key for another conversation.
    let other = try await Stores.open(s.dir)
    _ = try await other.lifecycle.remove("homebot")
    try await other.lifecycle.add(botB, cursor: "1", maxSeq: "1")
    #expect(await s.lifecycle.stillGranted(t.id, BotGrant(key: "homebot", sessionId: botA.sessionId)) == false)
    #expect(try await s.lifecycle.admit(t.token, bot: "homebot") == .invalid)
  }

  @Test("T3: a token whose bot's session changed is never marked used and never retires its predecessor")
  func admitMismatchNoActivation() async throws {
    let s = try await Stores.fresh()
    try await s.lifecycle.add(botA, cursor: "10", maxSeq: "10")
    let old = try await s.tokens.issue(bots: [BotGrant(key: "homebot", sessionId: botA.sessionId)], label: "v1")
    _ = try await s.lifecycle.admit(old.token)
    try await s.lifecycle.takeOver(old.id)
    // A genuine replacement whose stored session is not the bot's current one (written behind
    // the store's back, as an older build or a stale import would have left it).
    let next = try await s.tokens.issue(bots: [BotGrant(key: "homebot", sessionId: botA.sessionId)], label: "v2", replaces: old.id)
    var recs = try #require(try FileUtil.readJSON(TokenFile.self, from: s.tokens.file)).tokens
    recs[recs.firstIndex { $0.id == next.id }!].bots = [BotGrant(key: "homebot", sessionId: "777")]
    try FileUtil.writeJSON(s.tokens.file, TokenFile(tokens: recs))
    #expect(try await s.lifecycle.admit(next.token) == .invalid)
    #expect(try await s.lifecycle.admit(next.token, bot: "homebot") == .invalid)
    #expect(await s.tokens.state(next.id) == .pending)
    #expect(await s.tokens.usedAt(next.id) == nil)
    #expect(await s.tokens.state(old.id) == .active)
  }

  @Test("T4: setBots checks every bot under the lock")
  func setBots() async throws {
    let s = try await Stores.fresh()
    let a = Bot(key: "a", name: "A", sessionId: "1", strictEcho: true)
    let b = Bot(key: "b", name: "B", sessionId: "2", strictEcho: true)
    try await s.lifecycle.add(a, cursor: "1", maxSeq: "1")
    try await s.lifecycle.add(b, cursor: "1", maxSeq: "1")
    let t = try await s.tokens.issue(bots: [BotGrant(key: "a", sessionId: "1")], label: "x")
    try await s.lifecycle.setBots(t.id, [a, b])
    #expect(await s.tokens.list().first?.bots.map(\.key) == ["a", "b"])
    let stale = Bot(key: "b", name: "B", sessionId: "9", strictEcho: true)
    await #expect(throws: StoreError.self) { try await s.lifecycle.setBots(t.id, [a, stale]) }
  }
}
