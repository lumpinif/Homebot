// The activity store (DESIGN §20.6 A1–A7): one record per voice request that did work, in SQLite
// (WAL) at Activity/activity.sqlite, through the system SQLite3 C API. Only the gateway owner
// opens it (A5). Files are 0600 and the folder 0700; the folder is excluded from backups and the
// flag is read back before any text is written. Requests refused before authentication are only
// counted, one row per minute per (endpoint, outcome) (A3). Clear deletes the database with its
// -wal, -shm and -journal files and reopens a fresh one (A6).
import Foundation
import SQLite3

public struct ActivityRecord: Sendable, Equatable, Codable {
  /// Local random id (16 hex), unrelated to any wire id.
  public var id: String
  /// Start, ms since the epoch.
  public var at: Double
  public var durationMs: Int
  public var baselineMs: Int?
  public var sendMs: Int?
  public var replyMs: Int?
  /// The token's record id (12 hex, not a secret) and its label as they were at the time.
  public var tokenId: String
  public var label: String
  public var mode: String
  public var siriLang: String?
  public var botKey: String?
  public var botName: String?
  /// A local run number (per gateway start) and the step, for v2 requests.
  public var run: Int?
  public var step: Int?
  /// Bot turns only.
  public var question: String?
  public var tooLong: Bool
  /// Exactly what Siri was given to speak.
  public var spoken: String?
  public var outcome: String
  public var reason: String?
  /// Bot turns: which text delivery after the question was spoken (1-based), and how many
  /// untagged interim deliveries were skipped (DESIGN §4.2). Counts only, never text.
  public var delivery: Int?
  public var interim: Int?

  public init(id: String = Random.hex(bytes: 8), at: Double, durationMs: Int, baselineMs: Int? = nil, sendMs: Int? = nil, replyMs: Int? = nil, tokenId: String, label: String, mode: String, siriLang: String? = nil, botKey: String? = nil, botName: String? = nil, run: Int? = nil, step: Int? = nil, question: String? = nil, tooLong: Bool = false, spoken: String? = nil, outcome: String, reason: String? = nil, delivery: Int? = nil, interim: Int? = nil) {
    self.id = id
    self.at = at
    self.durationMs = durationMs
    self.baselineMs = baselineMs
    self.sendMs = sendMs
    self.replyMs = replyMs
    self.tokenId = tokenId
    self.label = label
    self.mode = mode
    self.siriLang = siriLang
    self.botKey = botKey
    self.botName = botName
    self.run = run
    self.step = step
    self.question = question
    self.tooLong = tooLong
    self.spoken = spoken
    self.outcome = outcome
    self.reason = reason
    self.delivery = delivery
    self.interim = interim
  }
}

/// Requests counted per minute (A3), and dropped records (`endpoint: "queue"`, `outcome: "dropped"`).
public struct ActivityCount: Sendable, Equatable, Codable {
  /// The minute's start, ms since the epoch.
  public var minute: Double
  public var endpoint: String
  public var outcome: String
  public var count: Int
}

public struct ActivityError: Error, CustomStringConvertible, Equatable {
  public let description: String
  init(_ d: String) { description = d }
}

public actor ActivityStore {
  public static let queueLimit = 1000
  public static let fileName = "activity.sqlite"

  public nonisolated let dir: URL
  public nonisolated var file: URL { dir.appendingPathComponent(ActivityStore.fileName) }
  /// The database and every file SQLite may keep next to it.
  public nonisolated var files: [URL] { ["", "-wal", "-shm", "-journal"].map { URL(fileURLWithPath: file.path + $0) } }

  /// False when the backup exclusion could not be set and read back: records keep no text.
  public private(set) var textAllowed = false
  public private(set) var isOpen = false

  var db: OpaquePointer?
  var queue: [ActivityRecord] = []
  /// When Clear last ran: a record of a request that started before it is dropped, so a question
  /// still being answered during Clear never comes back afterwards.
  var clearedAt: Double = 0
  var pendingCounts: [String: ActivityCount] = [:]
  var drainScheduled = false
  /// Tests: queue without writing, to fill the queue.
  var holdWrites = false
  let now: @Sendable () -> Double
  /// Tests: pretend the exclusion could not be read back.
  let exclusionCheck: @Sendable (URL) -> Bool

  public init(dir: URL, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }, exclusionCheck: (@Sendable (URL) -> Bool)? = nil) {
    self.dir = dir
    self.now = now
    self.exclusionCheck = exclusionCheck ?? ActivityStore.excludeFromBackup
  }

  /// Mark the folder excluded from backups and read the flag back (a fresh URL, no cache).
  public static func excludeFromBackup(_ dir: URL) -> Bool {
    var u = dir
    var rv = URLResourceValues()
    rv.isExcludedFromBackup = true
    do {
      try u.setResourceValues(rv)
    } catch {
      return false
    }
    let check = URL(fileURLWithPath: dir.path, isDirectory: true)
    return (try? check.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
  }

  /// Open (or create) the database. Called at every gateway start and after Clear.
  public func open() throws {
    if isOpen { return }
    try FileUtil.ensurePrivateDir(dir)
    var st = stat()
    guard lstat(dir.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { throw ActivityError("the activity folder is not a folder") }
    textAllowed = exclusionCheck(dir)
    // SQLite creates -wal, -shm and -journal with the mode of the database file, so the database
    // is created 0600 first, by us, without following a link.
    let fd = Darwin.open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw ActivityError("cannot open the activity database (errno \(errno))") }
    fchmod(fd, 0o600)
    Darwin.close(fd)
    for f in files.dropFirst() where FileUtil.mode(f).map({ $0 & 0o077 != 0 }) == true {
      chmod(f.path, 0o600)
    }
    // SQLite's NOFOLLOW refuses a link in any component of the path, so it gets the folder's
    // real path (/var is a link to /private/var); the file itself was checked above.
    // (Foundation's resolvingSymlinksInPath maps /private/var back to /var, so realpath(3).)
    guard let rp = realpath(dir.path, nil) else { throw ActivityError("cannot open the activity database") }
    let real = String(cString: rp) + "/" + ActivityStore.fileName
    free(rp)
    var handle: OpaquePointer?
    guard sqlite3_open_v2(real, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let h = handle else {
      sqlite3_close(handle)
      throw ActivityError("cannot open the activity database")
    }
    db = h
    do {
      try exec("PRAGMA journal_mode=WAL")
      try exec("PRAGMA synchronous=NORMAL")
      try exec("""
        CREATE TABLE IF NOT EXISTS records(
          id TEXT PRIMARY KEY, at INTEGER NOT NULL, duration_ms INTEGER NOT NULL,
          baseline_ms INTEGER, send_ms INTEGER, reply_ms INTEGER,
          token_id TEXT NOT NULL, label TEXT NOT NULL, mode TEXT NOT NULL, siri_lang TEXT,
          bot_key TEXT, bot_name TEXT, run INTEGER, step INTEGER,
          question TEXT, too_long INTEGER NOT NULL, spoken TEXT, outcome TEXT NOT NULL, reason TEXT,
          delivery INTEGER, interim INTEGER)
        """)
      // Databases made before the delivery counts get the two columns (NULL for old rows).
      let have = try columns("records")
      for c in ["delivery", "interim"] where !have.contains(c) { try exec("ALTER TABLE records ADD COLUMN \(c) INTEGER") }
      try exec("CREATE INDEX IF NOT EXISTS records_at ON records(at)")
      try exec("CREATE TABLE IF NOT EXISTS counts(minute INTEGER NOT NULL, endpoint TEXT NOT NULL, outcome TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY(minute, endpoint, outcome))")
    } catch {
      sqlite3_close(h)
      db = nil
      throw error
    }
    isOpen = true
  }

  public func close() {
    if let db { sqlite3_close(db) }
    db = nil
    isOpen = false
  }

  /// Queue a record (A1). Text fields are cleaned of protocol fragments once more here (the
  /// caller already removed the request's secrets) and dropped when text history is off.
  public func add(_ r: ActivityRecord) {
    guard isOpen, r.at >= clearedAt else { return }
    if queue.count >= ActivityStore.queueLimit {
      bump("queue", "dropped")
      return
    }
    var rec = r
    if textAllowed {
      rec.question = rec.question.map { ProtocolFilter.clean($0) }
      rec.spoken = rec.spoken.map { ProtocolFilter.clean($0) }
    } else {
      rec.question = nil
      rec.spoken = nil
    }
    queue.append(rec)
    schedule()
  }

  /// Count a request refused before authentication (A3).
  public func count(endpoint: String, outcome: String) {
    guard isOpen else { return }
    bump(endpoint, outcome)
    schedule()
  }

  private func bump(_ endpoint: String, _ outcome: String) {
    let minute = (now() / 60_000).rounded(.down) * 60_000
    let k = "\(Int(minute))|\(endpoint)|\(outcome)"
    pendingCounts[k, default: ActivityCount(minute: minute, endpoint: endpoint, outcome: outcome, count: 0)].count += 1
  }

  private func schedule() {
    if drainScheduled || holdWrites { return }
    drainScheduled = true
    Task { self.flush() }
  }

  /// Write everything queued (one transaction). Failures drop the batch; nothing is retried with text.
  public func flush() {
    drainScheduled = false
    if holdWrites { return }
    guard isOpen, !(queue.isEmpty && pendingCounts.isEmpty) else { return }
    let batch = queue
    let counts = Array(pendingCounts.values)
    queue = []
    pendingCounts = [:]
    do {
      try exec("BEGIN IMMEDIATE")
      for r in batch { try insert(r) }
      for c in counts {
        try run("INSERT INTO counts(minute, endpoint, outcome, n) VALUES(?,?,?,?) ON CONFLICT(minute, endpoint, outcome) DO UPDATE SET n = n + excluded.n",
                [.int(Int64(c.minute)), .text(c.endpoint), .text(c.outcome), .int(Int64(c.count))])
      }
      try exec("COMMIT")
    } catch {
      _ = try? exec("ROLLBACK")
    }
  }

  private func insert(_ r: ActivityRecord) throws {
    try run("INSERT OR IGNORE INTO records(\(ActivityStore.recordColumns)) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
      .text(r.id), .int(Int64(r.at)), .int(Int64(r.durationMs)), .optInt(r.baselineMs), .optInt(r.sendMs), .optInt(r.replyMs),
      .text(r.tokenId), .text(r.label), .text(r.mode), .optText(r.siriLang), .optText(r.botKey), .optText(r.botName),
      .optInt(r.run), .optInt(r.step), .optText(r.question), .int(r.tooLong ? 1 : 0), .optText(r.spoken), .text(r.outcome), .optText(r.reason),
      .optInt(r.delivery), .optInt(r.interim),
    ])
  }

  static let recordColumns = "id, at, duration_ms, baseline_ms, send_ms, reply_ms, token_id, label, mode, siri_lang, bot_key, bot_name, run, step, question, too_long, spoken, outcome, reason, delivery, interim"

  private func columns(_ table: String) throws -> Set<String> {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { throw ActivityError("cannot read the activity schema") }
    defer { sqlite3_finalize(stmt) }
    var out: Set<String> = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      if let c = sqlite3_column_text(stmt, 1) { out.insert(String(cString: c)) }
    }
    return out
  }

  /// The latest records, newest first.
  public func recent(limit: Int = 50) throws -> [ActivityRecord] {
    flush()
    guard let db else { throw ActivityError("the activity database is not open") }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT \(ActivityStore.recordColumns) FROM records ORDER BY at DESC, rowid DESC LIMIT ?", -1, &stmt, nil) == SQLITE_OK else {
      throw ActivityError("cannot read activity")
    }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int64(stmt, 1, Int64(max(limit, 0)))
    var out: [ActivityRecord] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      func text(_ i: Int32) -> String? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, i)) }
      func int(_ i: Int32) -> Int? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, i)) }
      out.append(ActivityRecord(
        id: text(0) ?? "", at: Double(int(1) ?? 0), durationMs: int(2) ?? 0, baselineMs: int(3), sendMs: int(4), replyMs: int(5),
        tokenId: text(6) ?? "", label: text(7) ?? "", mode: text(8) ?? "", siriLang: text(9), botKey: text(10), botName: text(11),
        run: int(12), step: int(13), question: text(14), tooLong: int(15) == 1, spoken: text(16), outcome: text(17) ?? "", reason: text(18),
        delivery: int(19), interim: int(20)))
    }
    return out
  }

  /// The newest record's start time and outcome: what `status` reports as the last request, so
  /// it survives a restart and agrees with the activity list.
  public func latest() throws -> (at: Double, outcome: String)? {
    try recent(limit: 1).first.map { ($0.at, $0.outcome) }
  }

  public func counts() throws -> [ActivityCount] {
    flush()
    guard let db else { throw ActivityError("the activity database is not open") }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT minute, endpoint, outcome, n FROM counts ORDER BY minute, endpoint, outcome", -1, &stmt, nil) == SQLITE_OK else {
      throw ActivityError("cannot read activity")
    }
    defer { sqlite3_finalize(stmt) }
    var out: [ActivityCount] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      out.append(ActivityCount(minute: Double(sqlite3_column_int64(stmt, 0)), endpoint: String(cString: sqlite3_column_text(stmt, 1)), outcome: String(cString: sqlite3_column_text(stmt, 2)), count: Int(sqlite3_column_int64(stmt, 3))))
    }
    return out
  }

  /// A6: stop taking records, discard what is queued, close, delete the database and its
  /// side files, and reopen a fresh one. Returns only when the old content is gone.
  public func clear() throws {
    clearedAt = now()
    queue = []
    pendingCounts = [:]
    close()
    for f in files {
      if unlink(f.path) != 0 && errno != ENOENT { throw ActivityError("cannot delete \(f.lastPathComponent) (errno \(errno))") }
    }
    try open()
  }

  // MARK: SQLite helpers

  enum Value {
    case int(Int64)
    case text(String)
    case null

    static func optInt(_ v: Int?) -> Value { v.map { .int(Int64($0)) } ?? .null }
    static func optText(_ v: String?) -> Value { v.map { .text($0) } ?? .null }
  }

  private func exec(_ sql: String) throws {
    guard let db, sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ActivityError("activity database error") }
  }

  private func run(_ sql: String, _ values: [Value]) throws {
    guard let db else { throw ActivityError("the activity database is not open") }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw ActivityError("activity database error") }
    defer { sqlite3_finalize(stmt) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (i, v) in values.enumerated() {
      let idx = Int32(i + 1)
      switch v {
      case .int(let n): sqlite3_bind_int64(stmt, idx, n)
      case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, transient)
      case .null: sqlite3_bind_null(stmt, idx)
      }
    }
    guard sqlite3_step(stmt) == SQLITE_DONE else { throw ActivityError("activity database error") }
  }
}

extension ActivityStore {
  /// Tests: hold or release writes.
  func setHoldWrites(_ v: Bool) { holdWrites = v }
  var queued: Int { queue.count }
}
