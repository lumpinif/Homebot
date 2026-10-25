// The activity store (DESIGN §20.6 A1–A7): SQLite through the system C API, private files,
// backup exclusion read back before text is written, bounded queue, per-minute counts, Clear.
import Foundation
import IOKit.pwr_mgt
import SQLite3
import Testing

@testable import HomebotCore

func rec(_ outcome: String = "answered", at: Double = 1_000, question: String? = "几点了", spoken: String? = "三点。") -> ActivityRecord {
  ActivityRecord(at: at, durationMs: 1200, baselineMs: 100, sendMs: 300, replyMs: 1100, tokenId: "aaaaaaaaaaaa", label: "问拆解师", mode: "single", siriLang: "zh-CN", botKey: "chai", botName: "拆解师", question: question, spoken: spoken, outcome: outcome)
}

@Suite("Activity store")
struct ActivityTests {
  @Test("files are private, the folder is excluded from backups, and a record round-trips")
  func roundTrip() async throws {
    let dir = try tmpDir().appendingPathComponent("Activity")
    let store = ActivityStore(dir: dir)
    try await store.open()
    #expect(await store.textAllowed, "the exclusion was set and read back")
    await store.add(rec())
    let got = try await store.recent()
    #expect(got.count == 1)
    var want = rec()
    want.id = got[0].id
    #expect(got[0] == want)
    #expect(FileUtil.mode(dir) == 0o700)
    for f in store.files.prefix(3) {
      #expect(FileUtil.mode(f) == 0o600, "\(f.lastPathComponent)")
    }
    #expect(try URL(fileURLWithPath: dir.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    await store.close()
  }

  @Test("delivery counts round-trip; a database made before them gains the columns, old rows read as nil")
  func deliveryCounts() async throws {
    let dir = try tmpDir().appendingPathComponent("Activity")
    try FileUtil.ensurePrivateDir(dir)
    var db: OpaquePointer?
    #expect(sqlite3_open(dir.appendingPathComponent(ActivityStore.fileName).path, &db) == SQLITE_OK)
    let old = """
      CREATE TABLE records(id TEXT PRIMARY KEY, at INTEGER NOT NULL, duration_ms INTEGER NOT NULL, baseline_ms INTEGER, send_ms INTEGER, reply_ms INTEGER,
        token_id TEXT NOT NULL, label TEXT NOT NULL, mode TEXT NOT NULL, siri_lang TEXT, bot_key TEXT, bot_name TEXT, run INTEGER, step INTEGER,
        question TEXT, too_long INTEGER NOT NULL, spoken TEXT, outcome TEXT NOT NULL, reason TEXT);
      INSERT INTO records VALUES('old', 500, 1, NULL, NULL, NULL, 'aaaaaaaaaaaa', 'l', 'single', NULL, NULL, NULL, NULL, NULL, NULL, 0, NULL, 'refused', 'O5');
      """
    #expect(sqlite3_exec(db, old, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let store = ActivityStore(dir: dir)
    try await store.open()
    var r = rec()
    r.delivery = 2
    r.interim = 1
    await store.add(r)
    let got = try await store.recent()
    #expect(got.map(\.id) == [r.id, "old"])
    #expect(got[0].delivery == 2 && got[0].interim == 1)
    #expect(got[1].delivery == nil && got[1].interim == nil && got[1].reason == "O5")
    await store.close()
  }

  @Test("tmutil reports the folder as excluded")
  func tmutil() async throws {
    let dir = try tmpDir().appendingPathComponent("Activity")
    let store = ActivityStore(dir: dir)
    try await store.open()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
    p.arguments = ["isexcluded", dir.path]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try p.run()
    p.waitUntilExit()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(text.contains("[Excluded]"), "tmutil isexcluded: \(text)")
    await store.close()
  }

  @Test("without a confirmed exclusion, records keep no text")
  func noExclusion() async throws {
    let store = ActivityStore(dir: try tmpDir().appendingPathComponent("Activity"), exclusionCheck: { _ in false })
    try await store.open()
    #expect(await store.textAllowed == false)
    await store.add(rec())
    let r = try await store.recent()
    #expect(r.first?.question == nil)
    #expect(r.first?.spoken == nil)
    #expect(r.first?.outcome == "answered")
    await store.close()
  }

  @Test("protocol fragments never reach the store")
  func filtered() async throws {
    let store = ActivityStore(dir: try tmpDir().appendingPathComponent("Activity"))
    try await store.open()
    await store.add(rec(question: "what is hb:0123456789ab", spoken: "[hb:0123456789ab] three o'clock"))
    let r = try await store.recent()
    #expect(r.first?.question?.contains("hb:") == false)
    #expect(r.first?.spoken?.trimmingCharacters(in: .whitespaces) == "three o'clock")
    await store.close()
  }

  @Test("A3: the queue is bounded and drops are counted; refusals are counted per minute")
  func boundedQueue() async throws {
    let t = Box<Double>(120_000)
    let store = ActivityStore(dir: try tmpDir().appendingPathComponent("Activity"), now: { t.value })
    try await store.open()
    await store.setHoldWrites(true)
    for i in 0..<(ActivityStore.queueLimit + 5) { await store.add(rec(at: Double(i))) }
    #expect(await store.queued == ActivityStore.queueLimit)
    for _ in 0..<3 { await store.count(endpoint: "/v1/ask", outcome: "bad-token") }
    t.value += 60_000
    await store.count(endpoint: "/v1/ask", outcome: "bad-token")
    await store.setHoldWrites(false)
    #expect(try await store.recent(limit: 5000).count == ActivityStore.queueLimit)
    let counts = try await store.counts()
    #expect(counts.contains(ActivityCount(minute: 120_000, endpoint: "queue", outcome: "dropped", count: 5)))
    #expect(counts.contains(ActivityCount(minute: 120_000, endpoint: "/v1/ask", outcome: "bad-token", count: 3)))
    #expect(counts.contains(ActivityCount(minute: 180_000, endpoint: "/v1/ask", outcome: "bad-token", count: 1)))
    await store.close()
  }

  @Test("A6: Clear discards queued records, deletes the database and its -wal/-shm, and reopens")
  func clear() async throws {
    let store = ActivityStore(dir: try tmpDir().appendingPathComponent("Activity"))
    try await store.open()
    await store.add(rec(question: "old question"))
    await store.flush()
    #expect(FileManager.default.fileExists(atPath: store.files[1].path), "WAL file exists before Clear")
    await store.setHoldWrites(true)
    await store.add(rec(question: "queued question"))
    let inode = try FileManager.default.attributesOfItem(atPath: store.file.path)[.systemFileNumber] as? Int
    try await store.clear()
    await store.setHoldWrites(false)
    #expect(try await store.recent().isEmpty)
    #expect(try await store.counts().isEmpty)
    let inode2 = try FileManager.default.attributesOfItem(atPath: store.file.path)[.systemFileNumber] as? Int
    #expect(inode != inode2, "a fresh database file")
    for f in store.files {
      if let data = FileManager.default.contents(atPath: f.path) {
        #expect(data.range(of: Data("old question".utf8)) == nil, "\(f.lastPathComponent) keeps no old text")
        #expect(data.range(of: Data("queued question".utf8)) == nil)
      }
    }
    // A request that started before Clear and finishes after it leaves no record (Codex S2 review 11).
    await store.add(rec(at: Date().timeIntervalSince1970 * 1000 - 5000, question: "in flight during Clear"))
    #expect(try await store.recent().isEmpty)
    await store.add(rec(at: Date().timeIntervalSince1970 * 1000 + 1))
    #expect(try await store.recent().count == 1, "records are taken again after Clear")
    await store.close()
  }

  @Test("a symlinked database is refused")
  func symlink() async throws {
    let dir = try tmpDir().appendingPathComponent("Activity")
    try FileUtil.ensurePrivateDir(dir)
    let target = try tmpDir().appendingPathComponent("elsewhere.sqlite")
    FileManager.default.createFile(atPath: target.path, contents: Data())
    try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(ActivityStore.fileName), withDestinationURL: target)
    let store = ActivityStore(dir: dir)
    await #expect(throws: ActivityError.self) { try await store.open() }
  }
}

@Suite("Awake")
struct AwakeTests {
  @Test("holds an idle-sleep assertion and an activity while serving; releases both")
  func holdRelease() throws {
    let a = AwakeService()
    #expect(a.hold())
    #expect(a.isHeld)
    let id = a.assertionID
    #expect(id != 0)
    var dict: Unmanaged<CFDictionary>?
    #expect(IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess)
    let all = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] ?? [:]
    let mine = all[NSNumber(value: getpid())] ?? []
    #expect(mine.contains { ($0["AssertionTrueType"] as? String ?? $0["AssertType"] as? String) == "PreventUserIdleSystemSleep" && ($0["AssertName"] as? String) == AwakeService.reason })
    #expect(a.hold(), "idempotent")
    #expect(a.assertionID == id)
    a.release()
    #expect(!a.isHeld)
  }
}
