// config.json (bots + settings, user-editable) and state.json (per-bot cursors, machine-owned).
// Ported from src/core/store.ts. Both are shared by the app and its CLI, so every write that can
// race another process is a locked read-modify-write against the current file (DESIGN D14).
import Foundation

/// How a bot's envelope style hint is set: the language default, none, or the user's own text.
public enum StyleHint: Sendable, Equatable {
  case standard
  case none
  case custom(String)
}

/// A bot as Homebot knows it. Identity is the session id, never the name (DESIGN §20.7).
public struct Bot: Sendable, Equatable {
  public var key: String
  /// Display name: "what Siri calls this bot" (editable; the API returns no current name).
  public var name: String
  public var sessionId: String
  public var strictEcho: Bool
  public var style: StyleHint
  /// Extra spoken names for the single-entry chooser (DESIGN §20.5, built in S4).
  public var aliases: [String]

  public init(key: String, name: String, sessionId: String, strictEcho: Bool, style: StyleHint = .standard, aliases: [String] = []) {
    self.key = key
    self.name = name
    self.sessionId = sessionId
    self.strictEcho = strictEcho
    self.style = style
    self.aliases = aliases
  }

  /// The longest display name the app accepts (the setup page's limit).
  public static let maxNameLength = 60
  /// Other names for the entry flow's menu (DESIGN §20.5).
  public static let maxAliases = 5

  public static func isValidKey(_ k: String) -> Bool {
    k.range(of: #"^[a-z0-9][a-z0-9-]{0,31}$"#, options: .regularExpression) != nil
  }

  public func validate() throws {
    guard Bot.isValidKey(key) else { throw StoreError("bot key must be 1-32 chars: a-z, 0-9, '-'") }
    guard sessionId.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil else { throw StoreError("session id must be numeric") }
  }
}

public struct StoreError: Error, CustomStringConvertible, Equatable {
  public let description: String
  public init(_ description: String) { self.description = description }
}

/// One bot's entry in config.json (the key is the dictionary key). `style`: absent = default,
/// null = no style hint, a string = custom text (the TypeScript file format).
struct BotEntry: Codable, Equatable {
  var name: String
  var sessionId: String
  var strictEcho: Bool
  var style: StyleHint
  var aliases: [String]

  enum CodingKeys: String, CodingKey { case name, sessionId, strictEcho, style, aliases }

  init(_ b: Bot) {
    name = b.name
    sessionId = b.sessionId
    strictEcho = b.strictEcho
    style = b.style
    aliases = b.aliases
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    sessionId = try c.decode(String.self, forKey: .sessionId)
    strictEcho = try c.decodeIfPresent(Bool.self, forKey: .strictEcho) ?? true
    if !c.contains(.style) {
      style = .standard
    } else if try c.decodeNil(forKey: .style) {
      style = .none
    } else {
      style = .custom(try c.decode(String.self, forKey: .style))
    }
    aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(name, forKey: .name)
    try c.encode(sessionId, forKey: .sessionId)
    try c.encode(strictEcho, forKey: .strictEcho)
    switch style {
    case .standard: break
    case .none: try c.encodeNil(forKey: .style)
    case .custom(let s): try c.encode(s, forKey: .style)
    }
    if !aliases.isEmpty { try c.encode(aliases, forKey: .aliases) }
  }

  func bot(_ key: String) -> Bot {
    Bot(key: key, name: name, sessionId: sessionId, strictEcho: strictEcho, style: style, aliases: aliases)
  }
}

/// Stored settings: every field optional; `Settings` fills in the defaults.
public struct SettingsPatch: Codable, Sendable, Equatable {
  public var answerBudgetMs: Int?
  public var pollMs: Int?
  public var maxSpokenChars: [String: Int]?
  public var port: Int?
  public var bind: String?
  public var maxQuestionChars: Int?
  public var rateLimitPerMin: Int?
  /// Conversation mode (DESIGN §18.3): how long a follow-up may wait for idle. 0 = answer busy.
  public var followupIdleMs: Int?
  public var siriLang: String?
  public var phoneLang: String?
  public var uiLang: String?
  /// The user agreed that Shortcuts are sent to Apple's signing service (DESIGN §7.5).
  public var appleSigning: Bool?
  /// Anonymous daily usage counts (Usage.swift). nil = never asked, which is off.
  public var usageCounts: Bool?
  /// The daily update check of the direct build. nil = on.
  public var updateCheck: Bool?

  public init() {}

  /// Fields set in `other` win.
  func merged(with o: SettingsPatch) -> SettingsPatch {
    var r = self
    if let v = o.answerBudgetMs { r.answerBudgetMs = v }
    if let v = o.pollMs { r.pollMs = v }
    if let v = o.maxSpokenChars { r.maxSpokenChars = v }
    if let v = o.port { r.port = v }
    if let v = o.bind { r.bind = v }
    if let v = o.maxQuestionChars { r.maxQuestionChars = v }
    if let v = o.rateLimitPerMin { r.rateLimitPerMin = v }
    if let v = o.followupIdleMs { r.followupIdleMs = v }
    if let v = o.siriLang { r.siriLang = v }
    if let v = o.phoneLang { r.phoneLang = v }
    if let v = o.uiLang { r.uiLang = v }
    if let v = o.appleSigning { r.appleSigning = v }
    if let v = o.usageCounts { r.usageCounts = v }
    if let v = o.updateCheck { r.updateCheck = v }
    return r
  }
}

/// Effective settings: stored values over the defaults (DEFAULT_SETTINGS in the TypeScript version).
public struct Settings: Sendable, Equatable {
  public var answerBudgetMs = 25_000
  public var pollMs = 500
  /// Per reply language; languages written without spaces count characters, so they get a lower
  /// cap. Unlisted languages use 600.
  public var maxSpokenChars: [String: Int] = Settings.defaultMaxSpokenChars
  public var port = 8787
  public var bind = "0.0.0.0"
  public var maxQuestionChars = 1000
  public var rateLimitPerMin = 10
  public var followupIdleMs = 0
  public var siriLang: String?
  public var phoneLang: String?
  public var uiLang: String?
  public var appleSigning: Bool?
  public var usageCounts: Bool?
  public var updateCheck: Bool?

  public static let defaultMaxSpokenChars: [String: Int] = ["zh-CN": 300, "zh-TW": 300, "ja": 300, "ko": 400, "en": 600]
  public static let fallbackMaxSpokenChars = 600

  public init() {}

  public init(_ p: SettingsPatch) {
    if let v = p.answerBudgetMs { answerBudgetMs = v }
    if let v = p.pollMs { pollMs = v }
    if let v = p.maxSpokenChars { maxSpokenChars.merge(v) { _, new in new } }
    if let v = p.port { port = v }
    if let v = p.bind { bind = v }
    if let v = p.maxQuestionChars { maxQuestionChars = v }
    if let v = p.rateLimitPerMin { rateLimitPerMin = v }
    if let v = p.followupIdleMs { followupIdleMs = v }
    siriLang = p.siriLang
    phoneLang = p.phoneLang
    uiLang = p.uiLang
    appleSigning = p.appleSigning
    usageCounts = p.usageCounts
    updateCheck = p.updateCheck
  }

  public func maxSpoken(_ replyLang: String) -> Int {
    maxSpokenChars[replyLang] ?? Settings.fallbackMaxSpokenChars
  }
}

struct ConfigData: Codable, Equatable {
  var bots: [String: BotEntry] = [:]
  var settings = SettingsPatch()

  init() {}

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    bots = try c.decodeIfPresent([String: BotEntry].self, forKey: .bots) ?? [:]
    settings = try c.decodeIfPresent(SettingsPatch.self, forKey: .settings) ?? SettingsPatch()
  }
}

/// config.json: bots and settings.
public actor ConfigStore {
  public nonisolated let file: URL
  var data = ConfigData()
  var fingerprint = ""

  public init(file: URL) {
    self.file = file
  }

  @discardableResult
  public func load() throws -> Self {
    let fp = FileUtil.fingerprint(file)
    data = try FileUtil.readJSON(ConfigData.self, from: file) ?? ConfigData()
    fingerprint = fp
    return self
  }

  /// Re-read if another process changed the file (writes are rename-based: new inode).
  public func refresh() throws {
    if FileUtil.fingerprint(file) != fingerprint { try load() }
  }

  func save() throws {
    try FileUtil.writeJSON(file, data)
    fingerprint = FileUtil.fingerprint(file)
  }

  public var settings: Settings { Settings(data.settings) }

  public func bot(_ key: String) -> Bot? {
    data.bots[key]?.bot(key)
  }

  /// All bots, ordered by key.
  public func bots() -> [Bot] {
    data.bots.keys.sorted().compactMap { bot($0) }
  }

  /// Validate a bot and refuse identity changes: a key never moves to another session (its
  /// cursor and token grants belong to the old one), and a session belongs to one key only.
  public func checkBot(_ b: Bot) throws {
    try b.validate()
    if let existing = bot(b.key), existing.sessionId != b.sessionId {
      throw StoreError("bot key \"\(b.key)\" already belongs to session \(existing.sessionId); choose another key")
    }
    if let other = bots().first(where: { $0.sessionId == b.sessionId && $0.key != b.key }) {
      throw StoreError("session \(b.sessionId) is already configured as bot \"\(other.key)\"")
    }
  }

  /// Callers hold the config lock (BotLifecycle) or own the file alone.
  public func putBot(_ b: Bot) throws {
    try checkBot(b)
    data.bots[b.key] = BotEntry(b)
    try save()
  }

  @discardableResult
  public func removeBot(_ key: String) throws -> Bool {
    guard data.bots[key] != nil else { return false }
    data.bots[key] = nil
    try save()
    return true
  }

  /// Under the same cross-process lock as bot changes, against the file as it is now, so two
  /// writers never drop each other's setting.
  public func putSettings(_ patch: SettingsPatch) async throws {
    let lock = try await FileLock.acquire(for: file)
    defer { lock.release() }
    try load()
    data.settings = data.settings.merged(with: patch)
    do {
      try save()
    } catch {
      // Never keep a setting in memory that isn't on disk (a consent that wasn't stored).
      try? load()
      throw error
    }
  }
}

/// A bot's position in its session. `sessionId`: the conversation this cursor belongs to.
public struct Cursor: Codable, Sendable, Equatable {
  public var cursor: String
  public var maxSeq: String
  public var syncedAt: Double
  public var sessionId: String?
}

struct StateData: Codable, Equatable {
  var cursors: [String: Cursor] = [:]

  init() {}

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    cursors = try c.decodeIfPresent([String: Cursor].self, forKey: .cursors) ?? [:]
  }
}

/// state.json: per-bot cursors. Written by the gateway (after each request) and by setup/CLI
/// (bot add/remove), so every write is a locked read-modify-write against the current file.
public actor StateStore {
  public nonisolated let file: URL
  var data = StateData()
  var fingerprint = ""
  let now: @Sendable () -> Double

  public init(file: URL, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
    self.file = file
    self.now = now
  }

  @discardableResult
  public func load() throws -> Self {
    let fp = FileUtil.fingerprint(file)
    data = try FileUtil.readJSON(StateData.self, from: file) ?? StateData()
    fingerprint = fp
    return self
  }

  public func refresh() throws {
    if FileUtil.fingerprint(file) != fingerprint { try load() }
  }

  public func cursor(_ bot: String) -> Cursor? {
    data.cursors[bot]
  }

  private func mutate(_ fn: (inout [String: Cursor]) throws -> Void) async throws {
    let lock = try await FileLock.acquire(for: file)
    defer { lock.release() }
    try load()
    try fn(&data.cursors)
    try FileUtil.writeJSON(file, data)
    fingerprint = FileUtil.fingerprint(file)
  }

  /// Record a bot's position. Normally forward-only and only for the same conversation: a write
  /// tagged with another session id than the stored one is dropped (a late write from a removed
  /// bot). `replace` (bot add, under the lifecycle lock) installs a fresh cold-sync cursor.
  public func setCursor(_ bot: String, cursor: String, maxSeq: String, sessionId: String? = nil, replace: Bool = false) async throws {
    let t = now()
    try await mutate { cursors in
      let prev = cursors[bot]
      let tag = sessionId ?? prev?.sessionId
      guard let prev, !replace else {
        cursors[bot] = Cursor(cursor: cursor, maxSeq: maxSeq, syncedAt: t, sessionId: tag)
        return
      }
      if let sessionId, let old = prev.sessionId, old != sessionId { return }
      let prevCursor = try Seq.parse(prev.cursor)
      if prevCursor > (try Seq.parse(cursor)) { return }
      let keepMax = try Seq.parse(prev.maxSeq) > (try Seq.parse(maxSeq))
      cursors[bot] = Cursor(cursor: cursor, maxSeq: keepMax ? prev.maxSeq : maxSeq, syncedAt: t, sessionId: tag)
    }
  }

  public func removeCursor(_ bot: String) async throws {
    try await mutate { cursors in cursors[bot] = nil }
  }
}
