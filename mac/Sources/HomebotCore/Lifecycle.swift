// One owner for a bot's identity: its config entry (key -> session), its cursor, and its grants
// in tokens (DESIGN §6.3 as amended by §20.5 T6). Every change runs under one cross-process lock
// on config.json and starts by re-reading the files, so the app, the CLI and the gateway can't
// interleave:
//  - removal drops the bot's grant from every token (retiring tokens left empty), then its
//    cursor and entry, in one step;
//  - token issuance re-checks under the lock that every bot still exists with the same session,
//    so a build that captured a bot before a removal (or a remove + re-add) gets nothing;
//  - adding re-checks identity under the lock before it installs the cursor, so a rejected
//    concurrent add never touches another bot's cursor.
// Lock order is always config -> state/tokens; nothing takes the config lock while holding those.
// Ported from src/core/lifecycle.ts.
import Foundation

public struct BotLifecycle: Sendable {
  public let config: ConfigStore
  public let state: StateStore
  public let tokens: TokenStore

  public init(config: ConfigStore, state: StateStore, tokens: TokenStore) {
    self.config = config
    self.state = state
    self.tokens = tokens
  }

  private func locked<T: Sendable>(_ fn: @Sendable () async throws -> T) async throws -> T {
    let lock = try await FileLock.acquire(for: config.file)
    defer { lock.release() }
    try await config.load()
    try await state.load()
    return try await fn()
  }

  /// Install a validated bot with its cold-sync cursor. Throws (changing nothing) if the key or
  /// session became taken while the sync ran.
  public func add(_ bot: Bot, cursor: String, maxSeq: String) async throws {
    try await locked {
      try await config.checkBot(bot)
      try await state.setCursor(bot.key, cursor: cursor, maxSeq: maxSeq, sessionId: bot.sessionId, replace: true)
      try await config.putBot(bot)
    }
  }

  /// Change what Siri and the app call a bot (DESIGN §20.7). The key and session stay; Shortcuts
  /// keep working. Returns false if the bot is unknown.
  @discardableResult
  public func rename(_ key: String, to name: String) async throws -> Bool {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= Bot.maxNameLength else { throw StoreError("a bot name has 1-\(Bot.maxNameLength) characters") }
    return try await locked {
      guard var b = await config.bot(key) else { return false }
      b.name = name
      try await config.putBot(b)
      return true
    }
  }

  /// Turn strict reply checking on or off for a bot (DESIGN §4.2). The key, session and Shortcuts
  /// stay. Returns false if the bot is unknown.
  @discardableResult
  public func setStrict(_ key: String, _ on: Bool) async throws -> Bool {
    try await locked {
      guard var b = await config.bot(key) else { return false }
      b.strictEcho = on
      try await config.putBot(b)
      return true
    }
  }

  /// Other names Siri may hear for a bot in the entry flow (DESIGN §20.5): the first one is the
  /// name spoken in the menu, e.g. a Mandarin name for a Latin-named bot on a Chinese HomePod.
  /// At most `Bot.maxAliases`, each 1-60 characters, no repeats. Returns false if the bot is unknown.
  @discardableResult
  public func setAliases(_ key: String, _ aliases: [String]) async throws -> Bool {
    let list = aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    // Clearing is an empty list; a name that is only spaces or punctuation can never be heard.
    guard list.allSatisfy({ !Chooser.norm($0).isEmpty }) else { throw StoreError("a name needs letters or characters Siri can hear") }
    guard list.count <= Bot.maxAliases else { throw StoreError("a bot has at most \(Bot.maxAliases) other names") }
    guard list.allSatisfy({ $0.count <= Bot.maxNameLength }) else { throw StoreError("a bot name has 1-\(Bot.maxNameLength) characters") }
    guard Set(list.map(Chooser.norm)).count == list.count else { throw StoreError("a name is listed twice") }
    return try await locked {
      guard var b = await config.bot(key) else { return false }
      b.aliases = list
      try await config.putBot(b)
      return true
    }
  }

  /// Remove a bot and everything bound to it. Returns the retired and narrowed token ids, or nil
  /// if the bot is unknown.
  public func remove(_ key: String) async throws -> (retired: [String], narrowed: [String])? {
    try await locked {
      guard await config.bot(key) != nil else { return nil }
      let r = try await tokens.revokeBot(key)
      try await state.removeCursor(key)
      try await config.removeBot(key)
      return r
    }
  }

  /// Run `issue` only while every bot still exists with the same session (M4 review B1).
  public func issueFor<T: Sendable>(_ bots: [Bot], _ issue: @Sendable ([Bot]) async throws -> T) async throws -> T {
    try await locked {
      var current: [Bot] = []
      for b in bots {
        guard let c = await config.bot(b.key), c.sessionId == b.sessionId else {
          throw StoreError("bot \"\(b.key)\" was removed or changed meanwhile; nothing was issued")
        }
        current.append(c)
      }
      return try await issue(current)
    }
  }

  /// T3: verify, admit and (when `use`) mark a pending token used, in one step under the
  /// config -> tokens locks, against the current config. The result's grant is the authorized
  /// (key, session) pair the turn must use. Nothing is activated or retired here (`takeOver`).
  public func admit(_ token: String?, bot: String? = nil, session: String? = nil, kind: TokenKind = .ask, use: Bool = true) async throws -> VerifyResult {
    let lock = try await FileLock.acquire(for: config.file)
    defer { lock.release() }
    try await config.refresh()
    let sessions = Dictionary(uniqueKeysWithValues: await config.bots().map { ($0.key, $0.sessionId) })
    return try await tokens.verify(token, bot: bot, session: session, kind: kind, sessionOf: { sessions[$0] }, use: use)
  }

  /// T5 takeover after a spoken answer (or a test Shortcut's first use): the token becomes active
  /// and retires what it replaces. `bot` is the bot that answered: the token must still grant it
  /// with the bot's current session (checked under the config lock, as `admit` does). Nothing is
  /// taken over once `stillThere` is false. Failures are logged by the caller, never spoken.
  @discardableResult
  public func takeOver(_ tokenId: String, bot: String? = nil, while stillThere: @Sendable () -> Bool = { true }) async throws -> Bool {
    let lock = try await FileLock.acquire(for: config.file)
    defer { lock.release() }
    try await config.refresh()
    var grant: BotGrant?
    if let key = bot {
      guard let b = await config.bot(key) else { return false }
      grant = BotGrant(key: key, sessionId: b.sessionId)
    }
    return try await tokens.takeOver(tokenId, grant: grant, while: stillThere)
  }

  /// Rule 3: the token still grants this exact pair and the bot still has that session.
  public func stillGranted(_ tokenId: String, _ grant: BotGrant) async -> Bool {
    guard (try? await config.refresh()) != nil, await config.bot(grant.key)?.sessionId == grant.sessionId else { return false }
    return (try? await tokens.grants(tokenId, grant)) ?? false
  }

  /// T4: change a Shortcut's bot set, checking every bot under the lock.
  public func setBots(_ tokenId: String, _ bots: [Bot]) async throws {
    try await issueFor(bots) { current in
      try await tokens.setBots(tokenId, current.map { BotGrant(key: $0.key, sessionId: $0.sessionId) })
    }
  }
}
