// Per-Shortcut client tokens (DESIGN D9, §7.5, §7.7, §20.5 T0–T6). Only SHA-256 hashes are
// stored. A token grants an explicit set of bots (T1); a per-bot Shortcut is a one-bot set. A new
// token starts `pending`; its first use that names or pins a bot marks it used (its file is then
// deleted). Its first request that ends with a spoken answer makes it `active` and retires the
// token it replaces (T5, DECISIONS item 27), so a replacement that has never answered never
// breaks a working Shortcut.
//
// tokens.json is the single authority shared by the app's gateway and the CLI: every mutation is
// a locked read-modify-write, and verify re-reads the file when it changed.
//
// Plaintext only leaves this module inside short-lived artifacts in the artifacts directory: a
// `<tokenId>/` directory holding a Shortcut file (or a `<tokenId>.<ext>` file). They are deleted
// once the token is used, revoked or expired, and when older than 24 h. An artifact is only ever
// created after its token record was written, and cleanup decides under the same lock against the
// file's current content, so a cleanup in one process never deletes another's fresh build.
// Ported from src/core/tokens.ts.
import CryptoKit
import Foundation

public enum TokenState: String, Codable, Sendable {
  case pending, active, retired
}

/// `ask`: voice Shortcuts (per-bot, conversation and entry). `probe`: the wait-limit test, only
/// for /v1/probe-wait. `lab`: the device-experiment Shortcut, only for /v1/lab. Test kinds never
/// replace or are replaced by a voice token.
public enum TokenKind: String, Codable, Sendable {
  case ask, probe, lab
}

/// The Shortcut's shape, for display and activity only (DESIGN §20.5): never used for
/// authorization or replacement, which compare `kind`. Every migrated TypeScript token is
/// `legacy` (the old records don't say which Shortcut they were made for).
public enum ShortcutMode: String, Codable, Sendable {
  case single, conversation, entry, legacy
}

/// One bot a token may use, tied to the bot's conversation (T1, T3).
public struct BotGrant: Codable, Sendable, Hashable {
  public var key: String
  public var sessionId: String

  public init(key: String, sessionId: String) {
    self.key = key
    self.sessionId = sessionId
  }
}

public struct TokenRecord: Codable, Sendable, Equatable {
  public var id: String
  public var hash: String
  public var bots: [BotGrant]
  public var label: String
  public var state: TokenState
  public var createdAt: Double
  public var activatedAt: Double?
  public var retiredAt: Double?
  /// The first admitted use of a pending token. A used pending token stays usable after the
  /// pending window: it is on a phone, waiting for its first answer.
  public var usedAt: Double?
  public var replaces: String?
  public var siriLang: String?
  /// Absent for voice tokens (`ask`), as in the TypeScript file.
  public var kind: TokenKind?
  public var mode: ShortcutMode?
  /// The first answer it got from this Mac itself (the Shortcut run in Shortcuts on the Mac), and
  /// the first from another device (an iPhone, or a HomePod through it). The app's Install page
  /// shows both; neither changes what the token may do.
  public var answeredHereAt: Double?
  public var answeredElsewhereAt: Double?

  public init(id: String, hash: String, bots: [BotGrant], label: String, state: TokenState, createdAt: Double, activatedAt: Double? = nil, retiredAt: Double? = nil, usedAt: Double? = nil, replaces: String? = nil, siriLang: String? = nil, kind: TokenKind? = nil, mode: ShortcutMode? = nil, answeredHereAt: Double? = nil, answeredElsewhereAt: Double? = nil) {
    self.id = id
    self.hash = hash
    self.bots = bots
    self.label = label
    self.state = state
    self.createdAt = createdAt
    self.activatedAt = activatedAt
    self.retiredAt = retiredAt
    self.usedAt = usedAt
    self.replaces = replaces
    self.siriLang = siriLang
    self.kind = kind
    self.mode = mode
    self.answeredHereAt = answeredHereAt
    self.answeredElsewhereAt = answeredElsewhereAt
  }

  public var effectiveKind: TokenKind { kind ?? .ask }
  public var botKeys: [String] { bots.map(\.key) }

  /// The token as shown to the UI or CLI: everything but the hash.
  public var info: TokenInfo {
    TokenInfo(id: id, bots: bots, label: label, state: state, createdAt: createdAt, activatedAt: activatedAt, retiredAt: retiredAt, usedAt: usedAt, replaces: replaces, siriLang: siriLang, kind: kind, mode: mode, answeredHereAt: answeredHereAt, answeredElsewhereAt: answeredElsewhereAt)
  }
}

public struct TokenInfo: Sendable, Equatable, Encodable {
  public var id: String
  public var bots: [BotGrant]
  public var label: String
  public var state: TokenState
  public var createdAt: Double
  public var activatedAt: Double?
  public var retiredAt: Double?
  public var usedAt: Double?
  public var replaces: String?
  public var siriLang: String?
  public var kind: TokenKind?
  public var mode: ShortcutMode?
  public var answeredHereAt: Double? = nil
  public var answeredElsewhereAt: Double? = nil
}

public enum VerifyResult: Sendable, Equatable {
  /// `bot`: the grant the request names or pins; nil only for an unpinned multi-bot token.
  case ok(TokenRecord, bot: BotGrant?)
  case invalid
  case forbidden

  public var isOK: Bool {
    if case .ok = self { return true }
    return false
  }

  public var record: TokenRecord? {
    if case .ok(let r, _) = self { return r }
    return nil
  }
}

public struct TokenError: Error, CustomStringConvertible, Equatable {
  public let description: String
  init(_ d: String) { description = d }
}

/// How labels (Siri phrases) are compared: NFC, trimmed, single spaces, case-insensitive.
/// "Space" is JavaScript's `\s` (U+FEFF included, U+0085 not), as in the TypeScript reference:
/// a phrase must not pass uniqueness by a space ICU's `\s` doesn't know.
public func labelKey(_ s: String) -> String {
  let space = #"[\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+"#
  return s.precomposedStringWithCanonicalMapping
    .replacingOccurrences(of: space, with: " ", options: .regularExpression)
    .trimmingCharacters(in: CharacterSet(charactersIn: " "))
    .lowercased()
}

struct TokenFile: Codable {
  var tokens: [TokenRecord] = []

  init(tokens: [TokenRecord]) { self.tokens = tokens }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    tokens = try c.decodeIfPresent([TokenRecord].self, forKey: .tokens) ?? []
  }
}

public actor TokenStore {
  public static let pendingTTLms: Double = 7 * 24 * 3600 * 1000
  public static let artifactTTLms: Double = 24 * 3600 * 1000
  /// T1: a set is spoken as a list in the entry flow, so it stays short.
  public static let maxBots = 9

  public nonisolated let file: URL
  public nonisolated let artifactsDir: URL?
  let now: @Sendable () -> Double
  public private(set) var records: [TokenRecord] = []
  var fingerprint = ""

  public init(file: URL, artifactsDir: URL? = nil, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
    self.file = file
    self.artifactsDir = artifactsDir
    self.now = now
  }

  @discardableResult
  public func load() throws -> Self {
    let fp = FileUtil.fingerprint(file)
    records = try FileUtil.readJSON(TokenFile.self, from: file)?.tokens ?? []
    fingerprint = fp
    return self
  }

  /// Re-read if another process changed the file.
  public func refresh() throws {
    if FileUtil.fingerprint(file) != fingerprint { try load() }
  }

  /// Locked read-modify-write against the latest file content, then artifact cleanup under the
  /// same lock.
  private func mutate<T>(_ fn: () throws -> T) async throws -> T {
    let lock = try await FileLock.acquire(for: file)
    defer { lock.release() }
    try load()
    // A change that throws (or fails to write) never leaves a half-edited cache behind.
    let snapshot = records
    let r: T
    do {
      r = try fn()
      try FileUtil.writeJSON(file, TokenFile(tokens: records))
    } catch {
      records = snapshot
      throw error
    }
    fingerprint = FileUtil.fingerprint(file)
    sweepArtifacts()
    return r
  }

  static func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static func checkSet(_ bots: [BotGrant]) throws {
    guard !bots.isEmpty else { throw TokenError("a Shortcut needs at least one bot") }
    guard bots.count <= maxBots else { throw TokenError("a Shortcut can answer for at most \(maxBots) bots") }
    guard Set(bots.map(\.key)).count == bots.count else { throw TokenError("a bot appears twice in this Shortcut's set") }
  }

  /// Issue a new pending token; the plaintext is returned once and never stored here.
  /// `uniqueLabel`: refuse when another non-retired token (other than `replaces`) has the same
  /// label: a Shortcut's label is its Siri phrase, and this check runs under the issuance lock
  /// (DESIGN §16.2). `replaces` must be a usable token of the same kind whose set is a subset of
  /// the new set (T6). Callers issue through BotLifecycle.issueFor (identity check).
  public func issue(bots: [BotGrant], label: String, replaces: String? = nil, siriLang: String? = nil, kind: TokenKind = .ask, mode: ShortcutMode? = nil, uniqueLabel: Bool = false) async throws -> (id: String, token: String) {
    try TokenStore.checkSet(bots)
    let token = Random.base64url(bytes: 32)
    let id = Random.hex(bytes: 6)
    let t = now()
    try await mutate {
      if let replaces {
        guard let old = records.first(where: { $0.id == replaces }), usable(old) else {
          throw TokenError("cannot replace \(replaces): no such usable token")
        }
        guard old.effectiveKind == kind else {
          throw TokenError("cannot replace \(replaces): test Shortcuts and voice Shortcuts never replace each other")
        }
        if let missing = old.bots.first(where: { !bots.contains($0) }) {
          throw TokenError("cannot replace \(replaces): it answers for bot \"\(missing.key)\", which the new Shortcut does not")
        }
      }
      // What this build takes the phrase over from: what it replaces and, through copies that were
      // never used (retired once the build succeeds, `supersedeUnused`), what those replace.
      let exempt = TokenStore.takeoverChain(from: replaces) { r in
        records.first { $0.id == r && $0.state == .pending && $0.usedAt == nil }?.replaces
      }
      if uniqueLabel, let clash = records.first(where: { $0.state != .retired && !exempt.contains($0.id) && labelKey($0.label) == labelKey(label) }) {
        throw TokenError("Another of your Homebot Shortcuts (token \(clash.id)) already uses \"\(label)\". Siri can't tell them apart. Revoke it first, or replace it.")
      }
      records.append(TokenRecord(id: id, hash: TokenStore.sha256Hex(token), bots: bots, label: label, state: .pending, createdAt: t, replaces: replaces, siriLang: siriLang, kind: kind == .ask ? nil : kind, mode: mode))
    }
    return (id, token)
  }

  /// The tokens a build takes the phrase over from: the one it replaces and, through copies that
  /// were never used (`unusedReplaces` gives what such a copy replaces, nil for any other token),
  /// what those replace. The phrase check exempts all of them, in the store and in the app.
  public static func takeoverChain(from replaces: String?, unusedReplaces: (String) -> String?) -> Set<String> {
    var chain: Set<String> = []
    var next = replaces
    while let r = next, !chain.contains(r) {
      chain.insert(r)
      next = unusedReplaces(r)
    }
    return chain
  }

  func usable(_ r: TokenRecord) -> Bool {
    r.state == .active || (r.state == .pending && (r.usedAt != nil || now() - r.createdAt < TokenStore.pendingTTLms))
  }

  /// Authenticate and authorize against the current file content (T3, T5).
  /// - `bot`: the requested bot; nil means "the token's own bot" (pinned only for a one-bot set).
  /// - `kind`: which endpoint is asking; checked before activation, so a token used at the wrong
  ///   endpoint never marks or retires anything.
  /// - `sessionOf`: the bot's current session (from config); a grant whose session differs is
  ///   dead (401). Omitted: no session check (callers that check elsewhere, and tests).
  /// - `use`: false for requests that only authenticate (the entry flow's choosing steps). A use
  ///   marks a pending token used; it never activates it or retires anything: that is `takeOver`,
  ///   after the request's answer was spoken.
  /// - `session`: with `bot`, the session the caller expects for it (the entry menu's snapshot):
  ///   any other grant is refused before anything is marked.
  public func verify(_ token: String?, bot: String? = nil, session: String? = nil, kind: TokenKind = .ask, sessionOf: (@Sendable (String) -> String?)? = nil, use: Bool = true) async throws -> VerifyResult {
    try refresh()
    let presented = Array(SHA256.hash(data: Data((token ?? "").utf8)))
    var match: TokenRecord?
    // Every record is compared in full, in constant time per record.
    for r in records {
      if TokenStore.constantTimeEqual(presented, TokenStore.bytes(hex: r.hash)) && usable(r) { match = r }
    }
    guard let found = match, found.effectiveKind == kind else { return .invalid }
    let live = found.bots.filter { g in sessionOf.map { $0(g.key) == g.sessionId } ?? true }
    var grant: BotGrant?
    if let bot {
      guard let g = found.bots.first(where: { $0.key == bot }) else { return .forbidden }
      guard live.contains(g) else { return .invalid }
      if let session, g.sessionId != session { return .invalid }
      grant = g
    } else if found.bots.count == 1 {
      guard let g = live.first else { return .invalid }
      grant = g
    } else if live.isEmpty {
      return .invalid
    }
    var rec = found
    if rec.state == .pending && rec.usedAt == nil && use && grant != nil {
      let id = rec.id
      let pinned = grant!
      let marked = try await mutate { () -> TokenRecord? in
        // Re-checked against the file as it is now: the grant must still be there.
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].bots.contains(pinned), usable(records[i]) else { return nil }
        if records[i].state == .pending && records[i].usedAt == nil { records[i].usedAt = now() }
        return records[i]
      }
      guard let m = marked, m.state != .retired else { return .invalid } // revoked or narrowed meanwhile
      rec = m
    }
    return .ok(rec, bot: grant)
  }

  /// Import only (TSImport): write migrated records into an empty store.
  func importRecords(_ recs: [TokenRecord]) async throws {
    try await mutate {
      guard records.isEmpty else { throw TokenError("the token store is not empty") }
      records = recs
    }
  }

  /// T5 takeover: a pending token whose request just ended with a spoken answer becomes `active`
  /// and retires what it replaces, in one locked write. Anything else (already active, retired,
  /// expired) changes nothing, so a second answer or a concurrent one is a no-op. Returns true
  /// when this call activated the token. `grant` is the pair that answered: the token must still
  /// grant it; `stillThere` is checked under the lock, so a client that left meanwhile (its answer
  /// was never spoken) takes nothing over.
  @discardableResult
  public func takeOver(_ id: String, grant: BotGrant? = nil, while stillThere: @Sendable () -> Bool = { true }) async throws -> Bool {
    try await mutate {
      guard let i = records.firstIndex(where: { $0.id == id }), records[i].state == .pending, usable(records[i]),
            grant.map({ records[i].bots.contains($0) }) ?? true, stillThere() else { return false }
      activateRecord(at: i)
      return true
    }
  }

  /// After a build succeeded: if the new token replaces a copy that was never used (made again
  /// before it was ever run), that copy is retired now and the new one takes over what it would
  /// have replaced, so the list never shows two "not used yet" versions of one Shortcut. Called
  /// only once the new file exists, so a failed build leaves the old copy alone.
  public func supersedeUnused(by id: String) async throws {
    try await mutate {
      guard let n = records.firstIndex(where: { $0.id == id }), records[n].state == .pending else { return }
      let t = now()
      let covered = Set(records[n].bots)
      // Down the chain of never-used copies to the Shortcut that is (or was) in use.
      var seen: Set<String> = [id]
      while let r = records[n].replaces, !seen.contains(r), let i = records.firstIndex(where: { $0.id == r }),
            records[i].state == .pending, records[i].usedAt == nil {
        seen.insert(r)
        records[i].state = .retired
        records[i].retiredAt = t
        records[n].replaces = records[i].replaces.flatMap { o in
          records.first { $0.id == o }.flatMap { usable($0) && Set($0.bots).isSubset(of: covered) ? o : nil }
        }
      }
    }
  }

  /// Records where a token's answer was spoken: from this Mac itself, or from another device. Only
  /// the first of each is kept, so at most two writes per token.
  public func noteAnswer(_ id: String, here: Bool) async throws {
    try refresh()
    guard let r = records.first(where: { $0.id == id }), (here ? r.answeredHereAt : r.answeredElsewhereAt) == nil else { return }
    try await mutate {
      guard let i = records.firstIndex(where: { $0.id == id }) else { return }
      if here, records[i].answeredHereAt == nil { records[i].answeredHereAt = now() }
      if !here, records[i].answeredElsewhereAt == nil { records[i].answeredElsewhereAt = now() }
    }
  }

  private func activateRecord(at i: Int) {
    let t = now()
    records[i].state = .active
    records[i].activatedAt = t
    if records[i].usedAt == nil { records[i].usedAt = t }
    // T5: the predecessor is retired only if the new token still covers every grant it has
    // (compared as (key, session) pairs); otherwise both stay usable and nothing is lost. Down a
    // chain of replacements (C replaces B replaces A) every covered one is retired, so an older
    // Shortcut never stays active behind a newer replacement that answered first.
    // The walk stops at a Shortcut that is not covered or already retired (its own takeover or a
    // revoke dealt with what is behind it).
    let covered = Set(records[i].bots)
    var next = records[i].replaces
    var seen: Set<String> = [records[i].id]
    while let old = next, !seen.contains(old), let j = records.firstIndex(where: { $0.id == old }),
          records[j].state != .retired, Set(records[j].bots).isSubset(of: covered) {
      seen.insert(old)
      records[j].state = .retired
      records[j].retiredAt = t
      next = records[j].replaces
    }
  }

  @discardableResult
  public func revoke(_ id: String) async throws -> Bool {
    try await mutate {
      guard let i = records.firstIndex(where: { $0.id == id }) else { return false }
      records[i].state = .retired
      records[i].retiredAt = now()
      return true
    }
  }

  /// T6: drop a removed bot's grant from every non-retired token in one locked write; tokens left
  /// with no grant are retired. Returns the retired ids and the narrowed ones.
  public func revokeBot(_ key: String) async throws -> (retired: [String], narrowed: [String]) {
    try await mutate {
      var retired: [String] = []
      var narrowed: [String] = []
      for i in records.indices where records[i].state != .retired && records[i].bots.contains(where: { $0.key == key }) {
        records[i].bots.removeAll { $0.key == key }
        if records[i].bots.isEmpty {
          records[i].state = .retired
          records[i].retiredAt = now()
          retired.append(records[i].id)
        } else {
          narrowed.append(records[i].id)
        }
      }
      return (retired, narrowed)
    }
  }

  /// T4: change a usable token's bot set in place. Never changes its state; never empties a set.
  public func setBots(_ id: String, _ bots: [BotGrant]) async throws {
    try TokenStore.checkSet(bots)
    try await mutate {
      guard let i = records.firstIndex(where: { $0.id == id }), usable(records[i]) else {
        throw TokenError("no such usable token: \(id)")
      }
      guard records[i].effectiveKind == .ask else { throw TokenError("test Shortcuts have no bot set to edit") }
      // A pending replacement must keep covering its predecessor (T4/T6).
      if records[i].state == .pending, let old = records[i].replaces,
         let o = records.first(where: { $0.id == old && usable($0) }),
         let missing = o.bots.first(where: { !bots.contains($0) }) {
        throw TokenError("this Shortcut replaces token \(old), which answers for bot \"\(missing.key)\"; drop it there first")
      }
      // Bots added or dropped here are added to or dropped from a pending replacement of this
      // token too, so it keeps covering this set and never keeps access the user removed.
      let added = bots.filter { !records[i].bots.contains($0) }
      let dropped = records[i].bots.filter { !bots.contains($0) }
      var mirrored: [(Int, [BotGrant])] = []
      // Every pending replacement down the chain (B replaces this one, C replaces B, …).
      var chain: [Int] = []
      var heads: Set<String> = [id]
      while true {
        let next = records.indices.filter { j in records[j].replaces.map(heads.contains) == true && records[j].state == .pending && usable(records[j]) && !chain.contains(j) }
        if next.isEmpty { break }
        chain += next
        heads = Set(next.map { records[$0].id })
      }
      for j in chain {
        let merged = records[j].bots.filter { !dropped.contains($0) } + added.filter { g in !records[j].bots.contains(g) }
        try TokenStore.checkSet(merged)
        mirrored.append((j, merged))
      }
      for (j, merged) in mirrored { records[j].bots = merged }
      records[i].bots = bots
    }
  }

  /// Whether a token is still pending and usable (a build checks this after writing its file).
  public func isPendingUsable(_ id: String) throws -> Bool {
    try refresh()
    guard let r = records.first(where: { $0.id == id }) else { return false }
    return r.state == .pending && usable(r)
  }

  /// Whether a usable token still grants exactly this (key, session) pair (rule 3: revalidation
  /// before every step and before a reply is spoken). Re-reads the file when it changed.
  public func grants(_ id: String, _ grant: BotGrant) throws -> Bool {
    try refresh()
    guard let r = records.first(where: { $0.id == id }), usable(r) else { return false }
    return r.bots.contains(grant)
  }

  /// Drop pending tokens that were never used within the TTL (a used one waiting for its first
  /// answer stays, DESIGN §7.7). Returns the removed ids.
  public func expirePending() async throws -> [String] {
    try await mutate {
      let dead = records.filter { $0.state == .pending && $0.usedAt == nil && now() - $0.createdAt >= TokenStore.pendingTTLms }.map(\.id)
      records.removeAll { dead.contains($0.id) }
      return dead
    }
  }

  /// Delete artifacts whose token is no longer pending, unknown, or older than 24 h.
  @discardableResult
  public func cleanupArtifacts() async throws -> [String] {
    guard artifactsDir != nil else { return [] }
    let lock = try await FileLock.acquire(for: file)
    defer { lock.release() }
    try load()
    return sweepArtifacts()
  }

  /// The caller holds the lock and has just loaded the file.
  @discardableResult
  private func sweepArtifacts() -> [String] {
    guard let dir = artifactsDir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
    var removed: [String] = []
    let t = now()
    for name in names.sorted() {
      guard let id = TokenStore.artifactId(name) else { continue }
      let path = dir.appendingPathComponent(name)
      let rec = records.first { $0.id == id }
      let age = FileUtil.ageMs(path, now: t) ?? t
      // A used token's file is gone at once: the plaintext lives on the phone now.
      if rec == nil || rec?.state != .pending || rec?.usedAt != nil || age >= TokenStore.artifactTTLms {
        try? FileManager.default.removeItem(at: path)
        removed.append(name)
      }
    }
    return removed
  }

  /// "<id>.<ext>" file or "<id>" directory.
  static func artifactId(_ name: String) -> String? {
    let id = name.prefix(12)
    guard id.count == 12, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
    let rest = name.dropFirst(12)
    guard rest.isEmpty || rest.first == "." else { return nil }
    return String(id)
  }

  public nonisolated func artifactPath(_ id: String, ext: String) throws -> URL {
    guard let dir = artifactsDir else { throw TokenError("no artifacts dir") }
    return dir.appendingPathComponent("\(id).\(ext)")
  }

  /// Per-token directory, for artifacts whose file name must be user-facing.
  public nonisolated func artifactDir(_ id: String) throws -> URL {
    guard let dir = artifactsDir else { throw TokenError("no artifacts dir") }
    return dir.appendingPathComponent(id, isDirectory: true)
  }

  /// Safe listing for UI/CLI: never includes hashes.
  public func list() -> [TokenInfo] {
    records.map(\.info)
  }

  static func bytes(hex: String) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(hex.utf8.count / 2)
    var it = hex.utf8.makeIterator()
    while let a = it.next(), let b = it.next() {
      guard let hi = hexVal(a), let lo = hexVal(b) else { return [] }
      out.append(hi << 4 | lo)
    }
    return out
  }

  private static func hexVal(_ c: UInt8) -> UInt8? {
    switch c {
    case 48...57: return c - 48
    case 97...102: return c - 87
    case 65...70: return c - 55
    default: return nil
    }
  }

  static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<a.count { diff |= a[i] ^ b[i] }
    return diff == 0
  }
}

/// T2: a token record from the TypeScript version (`~/.homebot/tokens.json`) in the new format.
/// `{bot, sessionId}` becomes a one-bot set with mode `legacy`; hash, id, label, state, times,
/// `replaces`, `siriLang` and `kind` are kept, so Shortcuts already on the phone keep working. A
/// record without a session (made before M4) has no evidence of its conversation: it is imported
/// retired unless the user chose to keep it (`bindSessionless`), which binds it to the bot's
/// current session. A record whose bot is gone (`sessionOf` nil) is imported retired. Used by the
/// import (S2).
public func migrateTypeScriptToken(_ json: [String: Any], sessionOf: (String) -> String?, now: Double, bindSessionless: Bool = false) -> TokenRecord? {
  guard let id = json["id"] as? String, TokenStore.artifactId(id) == id,
        let hash = json["hash"] as? String, hash.count == 64,
        let bot = json["bot"] as? String,
        let label = json["label"] as? String,
        let stateRaw = json["state"] as? String, var state = TokenState(rawValue: stateRaw),
        let createdAt = (json["createdAt"] as? NSNumber)?.doubleValue
  else { return nil }
  var retiredAt = (json["retiredAt"] as? NSNumber)?.doubleValue
  let stored = json["sessionId"] as? String
  let current = sessionOf(bot)
  let session = stored ?? (bindSessionless ? current : nil)
  if (session == nil || current == nil) && state != .retired {
    state = .retired
    retiredAt = now
  }
  let kind: TokenKind?
  switch json["kind"] as? String {
  case nil: kind = nil
  case "probe": kind = .probe
  case "lab": kind = .lab
  default: return nil
  }
  return TokenRecord(
    id: id, hash: hash, bots: [BotGrant(key: bot, sessionId: session ?? "")], label: label, state: state, createdAt: createdAt,
    activatedAt: (json["activatedAt"] as? NSNumber)?.doubleValue, retiredAt: retiredAt,
    replaces: json["replaces"] as? String, siriLang: json["siriLang"] as? String, kind: kind, mode: .legacy)
}
