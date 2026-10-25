// Ported from test/home.test.ts and test/store-log.test.ts: the support directory, private
// files, config/state stores, cold sync's time cap, the JSONL log.
import Foundation
import Testing

@testable import HomebotCore

func modeOf(_ u: URL) -> mode_t { (FileUtil.mode(u) ?? 0) & 0o777 }

@Suite("Home and private files")
struct HomeTests {
  @Test("home dir and subdirs are created 0700")
  func create() throws {
    let root = try tmpDir().appendingPathComponent("hb")
    let home = try Home(root: root)
    try home.prepare()
    #expect(modeOf(root) == 0o700)
    #expect(modeOf(home.logs) == 0o700)
    #expect(modeOf(home.shortcuts) == 0o700)
  }

  @Test("an existing world-readable home dir is tightened")
  func tighten() throws {
    let root = try tmpDir().appendingPathComponent("hb")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    try Home(root: root).prepare()
    #expect(modeOf(root) == 0o700)
  }

  @Test("refuses a home inside a git work tree")
  func git() throws {
    let repo = try tmpDir()
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: false)
    let data = repo.appendingPathComponent("data")
    #expect(Home.findGitRoot(data)?.standardizedFileURL.path == repo.standardizedFileURL.path)
    #expect(throws: FileUtil.FileError.self) { try Home(root: data) }
    #expect(throws: Never.self) { try Home(root: data, allowInGit: true) }
  }

  @Test("a home that is a symlink into a git work tree is refused")
  func gitViaSymlink() throws {
    let repo = try tmpDir()
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: false)
    let inside = repo.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: false)
    let link = try tmpDir().appendingPathComponent("hb")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inside)
    #expect(throws: FileUtil.FileError.self) { try Home(root: link) }
  }

  @Test("the default location is ~/Library/Application Support/Homebot")
  func defaultRoot() {
    #expect(Home.defaultRoot().path.hasSuffix("/Library/Application Support/Homebot"))
  }

  @Test("private files are 0600 and JSON round-trips")
  func json() throws {
    let dir = try tmpDir()
    let f = dir.appendingPathComponent("sub/secrets.json")
    try FileUtil.writeJSON(f, ["a": 1])
    #expect(modeOf(f) == 0o600)
    #expect(modeOf(dir.appendingPathComponent("sub")) == 0o700)
    #expect(try FileUtil.readJSON([String: Int].self, from: f) == ["a": 1])
    #expect(try FileUtil.readJSON([String: Int].self, from: dir.appendingPathComponent("missing.json")) == nil)
  }

  @Test("malformed JSON fails with a fixed message, never the content")
  func malformed() throws {
    let f = try tmpDir().appendingPathComponent("config.json")
    try Data(#"{"x": dummy-secret-value-123}"#.utf8).write(to: f)
    let e = try #require(throws: FileUtil.FileError.self) { try FileUtil.readJSON([String: String].self, from: f) }
    #expect(e.description.contains("config.json is not valid JSON"))
    #expect(!e.description.contains("dummy"))
  }

  @Test("overwriting keeps 0600 and leaves no temp files")
  func overwrite() throws {
    let dir = try tmpDir()
    let f = dir.appendingPathComponent("x.json")
    try FileUtil.writePrivateFile(f, "1")
    try FileUtil.writePrivateFile(f, "2")
    #expect(modeOf(f) == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["x.json"])
    #expect(try String(contentsOf: f, encoding: .utf8) == "2")
  }

  @Test("a symlink at the target is replaced, never written through")
  func symlink() throws {
    let dir = try tmpDir()
    let victim = dir.appendingPathComponent("victim")
    try "keep".write(to: victim, atomically: true, encoding: .utf8)
    let f = dir.appendingPathComponent("x.json")
    try FileManager.default.createSymbolicLink(at: f, withDestinationURL: victim)
    try FileUtil.writePrivateFile(f, "new")
    #expect(try String(contentsOf: victim, encoding: .utf8) == "keep")
    #expect(try String(contentsOf: f, encoding: .utf8) == "new")
  }

  @Test("the startup sweep removes leftover temp files")
  func sweep() throws {
    let root = try tmpDir().appendingPathComponent("hb")
    let home = try Home(root: root)
    try home.prepare()
    let old = root.appendingPathComponent(".secrets.json.abc\(FileUtil.tmpSuffix)")
    let oldInShortcuts = home.shortcuts.appendingPathComponent(".x.abc\(FileUtil.tmpSuffix)")
    let fresh = root.appendingPathComponent(".config.json.def\(FileUtil.tmpSuffix)")
    for f in [old, oldInShortcuts, fresh] { try Data("partial".utf8).write(to: f) }
    let longAgo = Date(timeIntervalSinceNow: -3600)
    for f in [old, oldInShortcuts] { try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: f.path) }
    try home.prepare()
    #expect(FileManager.default.fileExists(atPath: fresh.path), "a write in progress in another process is never broken")
    try FileManager.default.removeItem(at: fresh)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(FileUtil.tmpSuffix) } == [])
    #expect(try FileManager.default.contentsOfDirectory(atPath: home.shortcuts.path) == [])
  }
}

@Suite("File lock (DESIGN §20.5 T0)")
struct LockTests {
  @Test("a second acquisition waits, and times out while the first holds")
  func exclusive() async throws {
    let f = try tmpDir().appendingPathComponent("tokens.json")
    let a = try await FileLock.acquire(for: f)
    await #expect(throws: FileUtil.FileError.self) { _ = try await FileLock.acquire(for: f, timeoutMs: 50) }
    a.release()
    let b = try await FileLock.acquire(for: f, timeoutMs: 50)
    b.release()
  }

  @Test("an old lock file left by a dead holder never blocks (kernel lock, not file presence)")
  func leftover() async throws {
    let f = try tmpDir().appendingPathComponent("tokens.json")
    try Data().write(to: URL(fileURLWithPath: f.path + ".lock"))
    let l = try await FileLock.acquire(for: f, timeoutMs: 50)
    l.release()
  }

  @Test("a held lock is never broken by elapsed time")
  func noStaleBreak() async throws {
    let f = try tmpDir().appendingPathComponent("tokens.json")
    let a = try await FileLock.acquire(for: f)
    try await Task.sleep(nanoseconds: 300_000_000)
    await #expect(throws: FileUtil.FileError.self) { _ = try await FileLock.acquire(for: f, timeoutMs: 100) }
    a.release()
  }

  @Test("a lock held by another process is released by the kernel when it dies", .timeLimit(.minutes(1)))
  func processDeath() async throws {
    let f = try tmpDir().appendingPathComponent("tokens.json")
    let lock = f.path + ".lock"
    // A child takes the lock with flock(1)-like semantics via Perl, then is killed.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    p.arguments = ["-e", "use Fcntl qw(:flock); open(my $f, '>>', $ARGV[0]) or die; flock($f, LOCK_EX) or die; print \"locked\\n\"; $| = 1; sleep 30;", lock]
    let out = Pipe()
    p.standardOutput = out
    // Not waitUntilExit(): after an `await` the test may resume on another thread than the one
    // that launched the child, and the exit notice goes to the launching thread's run loop, so
    // waitUntilExit() could block forever (one full-suite run in 13 hung here, S5).
    let (exited, ended) = AsyncStream<Void>.makeStream()
    p.terminationHandler = { _ in ended.finish() }
    try p.run()
    _ = out.fileHandleForReading.availableData // "locked"
    await #expect(throws: FileUtil.FileError.self) { _ = try await FileLock.acquire(for: f, timeoutMs: 100) }
    p.terminate()
    for await _ in exited {}
    let l = try await FileLock.acquire(for: f, timeoutMs: 1000)
    l.release()
  }
}

@Suite("Config, state and log stores")
struct StoreTests {
  @Test("config: defaults merge, bot validation, reserved names are not bots")
  func config() async throws {
    let dir = try tmpDir()
    let c = ConfigStore(file: dir.appendingPathComponent("config.json"))
    try await c.load()
    var patch = SettingsPatch()
    patch.answerBudgetMs = 9000
    patch.maxSpokenChars = ["en": 100]
    try await c.putSettings(patch)
    let s = await c.settings
    #expect(s.answerBudgetMs == 9000)
    #expect(s.pollMs == Settings().pollMs)
    #expect(s.maxSpokenChars == Settings.defaultMaxSpokenChars.merging(["en": 100]) { $1 })
    await #expect(throws: StoreError.self) { try await c.putBot(Bot(key: "../x", name: "x", sessionId: "1", strictEcho: true)) }
    let numeric = await errorText { try await c.putBot(Bot(key: "ok", name: "x", sessionId: "da83afad-uuid", strictEcho: true)) }
    #expect(numeric?.contains("numeric") == true)
    try await c.putBot(Bot(key: "chai", name: "拆解师", sessionId: "14752726", strictEcho: true))
    #expect(await c.bot("constructor") == nil)
    #expect(await c.bot("__proto__") == nil)
    let again = ConfigStore(file: c.file)
    try await again.load()
    #expect(await again.bot("chai")?.sessionId == "14752726")
    #expect(modeOf(c.file) == 0o600)
  }

  @Test("config: a settings write never drops another writer's setting")
  func settingsMerge() async throws {
    let f = try tmpDir().appendingPathComponent("config.json")
    let a = ConfigStore(file: f)
    let b = ConfigStore(file: f)
    try await a.load()
    try await b.load()
    var p1 = SettingsPatch()
    p1.port = 9000
    var p2 = SettingsPatch()
    p2.pollMs = 250
    try await a.putSettings(p1)
    try await b.putSettings(p2)
    let fresh = ConfigStore(file: f)
    try await fresh.load()
    #expect(await fresh.settings.port == 9000)
    #expect(await fresh.settings.pollMs == 250)
  }

  @Test("S3: a key never moves to another session; a session has one key")
  func identity() async throws {
    let c = ConfigStore(file: try tmpDir().appendingPathComponent("config.json"))
    try await c.load()
    try await c.putBot(Bot(key: "chai", name: "拆解师", sessionId: "100", strictEcho: true))
    try await c.putBot(Bot(key: "chai", name: "Renamed", sessionId: "100", strictEcho: false)) // same identity: OK
    let moved = await errorText { try await c.checkBot(Bot(key: "chai", name: "x", sessionId: "200", strictEcho: true)) }
    #expect(moved?.contains("already belongs to session 100") == true)
    let alias = await errorText { try await c.putBot(Bot(key: "alias", name: "x", sessionId: "100", strictEcho: true)) }
    #expect(alias?.contains("already configured as bot \"chai\"") == true)
    #expect(await c.bot("chai")?.sessionId == "100")
    #expect(await c.bot("alias") == nil)
  }

  @Test("state: cursors only move forward; maxSeq never decreases")
  func cursors() async throws {
    let s = StateStore(file: try tmpDir().appendingPathComponent("state.json"))
    try await s.load()
    try await s.setCursor("chai", cursor: "500", maxSeq: "480")
    try await s.setCursor("chai", cursor: "300", maxSeq: "900")
    #expect(await s.cursor("chai")?.cursor == "500")
    try await s.setCursor("chai", cursor: "600", maxSeq: "100")
    #expect(await s.cursor("chai")?.cursor == "600")
    #expect(await s.cursor("chai")?.maxSeq == "480")
    #expect(await s.cursor("hasOwnProperty") == nil)
  }

  @Test("cold sync has a total time cap, not just a page cap")
  func coldSyncCap() async throws {
    let slow = SlowBdk()
    let e = await errorText { _ = try await Bots.coldSync(slow, sessionId: "1", timeoutMs: 120) }
    #expect(e?.contains("longer than") == true)
    #expect(slow.count < 10)
  }

  @Test("cold sync returns the cursor, max seq and the latest bot text")
  func coldSyncResult() async throws {
    let fake = FakeGrokBot()
    fake.add("42", kind: "message", role: "user", text: "q")
    let first = fake.add("42", kind: "send-message", text: "first")
    fake.add("42", kind: "send-message", text: "  ")
    fake.touch("42", seq: first.seq) // re-updated: cursor moves, max creation seq doesn't
    let r = try await Bots.coldSync(fake.client(), sessionId: "42")
    #expect(r.cursor == "1004")
    #expect(r.maxSeq == "1003")
    #expect(r.entryCount == 3)
    #expect(r.latestBotText == "first")
  }

  @Test("logger: 0600 file, JSON lines in order, rotation keeps 3 files")
  func logger() async throws {
    let dir = try tmpDir()
    let logger = JSONLLogger(dir: dir, maxBytes: 200)
    for i in 0..<30 { await logger.write(["event": "x", "i": .int(i), "pad": .string(String(repeating: "y", count: 40))]) }
    #expect(modeOf(logger.file) == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["homebot.jsonl", "homebot.jsonl.1", "homebot.jsonl.2", "homebot.jsonl.3", "homebot.jsonl.lock"])
    let lines = try String(contentsOf: logger.file, encoding: .utf8).split(separator: "\n")
    let last = try JSONSerialization.jsonObject(with: Data(lines.last!.utf8)) as? [String: Any]
    #expect(last?["i"] as? Int == 29)
    #expect(last?["ts"] is String)
  }

  @Test("logger: two loggers on one directory (app and CLI) never lose each other's lines")
  func twoLoggers() async throws {
    let dir = try tmpDir()
    let a = JSONLLogger(dir: dir, maxBytes: 100_000)
    let b = JSONLLogger(dir: dir, maxBytes: 100_000)
    await withTaskGroup(of: Void.self) { g in
      for i in 0..<50 {
        g.addTask { await a.write(["w": "a", "i": .int(i)]) }
        g.addTask { await b.write(["w": "b", "i": .int(i)]) }
      }
    }
    let lines = try String(contentsOf: a.file, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 100)
    #expect(lines.allSatisfy { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) != nil }, "no torn lines")
  }

  @Test("logger: the fire-and-forget function keeps order")
  func loggerFn() async throws {
    let dir = try tmpDir()
    let logger = JSONLLogger(dir: dir)
    let fn = logger.fn
    for i in 0..<20 { fn(["i": .int(i)]) }
    var lines: [Substring] = []
    for _ in 0..<200 {
      lines = ((try? String(contentsOf: logger.file, encoding: .utf8)) ?? "").split(separator: "\n")
      if lines.count == 20 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let order = lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["i"] as? Int }
    #expect(order == Array(0..<20))
  }

  @Test("R2: errorName logs only known error classes")
  func errorNames() {
    struct Synthetic: Error {}
    #expect(Log.errorName(BdkError(message: "x", kind: .auth, status: 401)) == "BdkError")
    #expect(Log.errorName(CancellationError()) == "AbortError")
    #expect(Log.errorName(URLError(.timedOut)) == "TimeoutError")
    #expect(Log.errorName(Synthetic()) == "other")
    #expect(Log.errorName(nil) == "non-error")
  }
}

/// getEntries takes 30 ms per page and never ends; honours cancellation.
final class SlowBdk: BdkClient, @unchecked Sendable {
  private let lock = NSLock()
  private var n = 0
  var count: Int { lock.withLock { n } }

  func getOrCreateSession(name: String) async throws -> NamedSession { Issue.record("not used"); throw CancellationError() }
  func sendMessage(sessionId: String, messageId: String, text: String) async throws -> SendResult { Issue.record("not used"); throw CancellationError() }
  func getEntries(sessionId: String, afterUpdatedSeq: String) async throws -> Page {
    try await Task.sleep(nanoseconds: 30_000_000)
    let k = lock.withLock { n += 1; return n }
    return Page(entries: [Entry(seq: String(k), updatedSeq: String(k), kind: "message")], latestUpdatedSeq: String(k), turn: Turn())
  }
}
