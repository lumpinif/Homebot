// The TypeScript folder importer (§20.11) and the gateway parity check, on a folder the
// TypeScript CLI made against the fake Grok Bot API (scripts/swift-gateway-golden.ts writes
// Fixtures/ts-home and Fixtures/gateway-golden.json). Never run against a live ~/.homebot.
import Foundation
import Testing

@testable import HomebotCore
@testable import HomebotGateway
import HomebotTestSupport

let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)

struct Golden: Decodable {
  struct Tok: Decodable {
    let id: String
    let token: String
  }
  struct Req: Decodable {
    let token: String
    let method: String?
    let path: String?
    let body: JSONValue?
    let raw: String?
  }
  struct Scenario: Decodable {
    let name: String
    let req: Req
    let bot: BotSetup?
    let status: Int
    let contentType: String
    let answer: String
  }
  struct BotSetup: Decodable {
    let sid: String
    let text: String?
    let echo: Bool?
    let more: [String]?
    let busy: Bool?
  }
  let key: String
  let tokens: [String: Tok]
  let transcripts: [String: [FakeGrokBot.FakeEntry]]
  let scenarios: [Scenario]

  static func load() throws -> Golden {
    try JSONDecoder().decode(Golden.self, from: Data(contentsOf: fixtures.appendingPathComponent("gateway-golden.json")))
  }
}

/// Any JSON value, re-encoded as written (for request bodies).
enum JSONValue: Decodable {
  case v(Any)
  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let s = try? c.decode(String.self) { self = .v(s); return }
    if let b = try? c.decode(Bool.self) { self = .v(b); return }
    if let n = try? c.decode(Double.self) { self = .v(n); return }
    if let o = try? c.decode([String: JSONValue].self) { self = .v(o.mapValues { $0.any }); return }
    if let a = try? c.decode([JSONValue].self) { self = .v(a.map(\.any)); return }
    self = .v(NSNull())
  }
  var any: Any { if case .v(let x) = self { return x } else { return NSNull() } }
}

/// A private copy of the TypeScript fixture folder.
func tsCopy() throws -> URL {
  let dir = try shortTmpDir().appendingPathComponent("dot-homebot", isDirectory: true)
  try FileManager.default.copyItem(at: fixtures.appendingPathComponent("ts-home"), to: dir)
  chmod(dir.path, 0o700)
  return dir
}

func newHome() throws -> Home { try Home(root: try shortTmpDir().appendingPathComponent("Homebot", isDirectory: true)) }

@Suite("Import and parity with the TypeScript gateway", .serialized)
struct ImportParityTests {
  @Test("import: bots, cursors, settings, tokens (T2) and the key; the old folder is marked as moved")
  func importsFixture() async throws {
    let g = try Golden.load()
    let src = try tsCopy()
    let home = try newHome()
    let p = try TSImport.preview(src)
    #expect(p.bots.map(\.key) == ["chai", "kitchen"])
    #expect(p.tokens.count == 5 && p.hasKey && !p.moved)
    #expect(p.tokens.filter(\.sessionless).map(\.id) == [g.tokens["pending"]!.id])
    let r = try await TSImport.run(from: src, to: home, isListening: { _ in false })
    #expect(r == TSImport.Report(bots: 2, cursors: 2, usable: 3, retired: 2, keyCopied: true))
    let s = try await Stores(home)
    #expect(await s.config.bot("kitchen")?.strictEcho == false)
    let settings = await s.config.settings
    #expect(settings.siriLang == "zh-CN" && settings.rateLimitPerMin == 100)
    #expect(await s.state.cursor("chai")?.sessionId == chai.sessionId)
    let states = Dictionary(uniqueKeysWithValues: await s.tokens.list().map { ($0.id, $0.state) })
    #expect(states[g.tokens["zh"]!.id] == .active && states[g.tokens["kitchen"]!.id] == .active)
    #expect(states[g.tokens["revoked"]!.id] == .retired)
    #expect(states[g.tokens["pending"]!.id] == .retired, "a sessionless token is retired unless kept (T2)")
    #expect(try Credentials(keyFile: home.apiKey, userHome: home.root).savedKey() == g.key)
    #expect((FileUtil.mode(home.apiKey) ?? 0) & 0o777 == 0o600)
    let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: src.appendingPathComponent(TSImport.markerName))) as? [String: Any]
    #expect(marker?["movedTo"] as? String == home.root.path)
    #expect(try TSImport.preview(src).moved)
    for name in ["config.json", "state.json", "tokens.json"] {
      #expect(!FileManager.default.fileExists(atPath: src.appendingPathComponent(name + ".lock").path), "the old locks are released")
    }
    await #expect(throws: TSImport.ImportError.self, "a second import is refused") { try await TSImport.run(from: src, to: try newHome(), isListening: { _ in false }) }
  }

  @Test("import: --keep binds a pre-M4 token to its bot's conversation")
  func keepSessionless() async throws {
    let g = try Golden.load()
    let home = try newHome()
    let r = try await TSImport.run(from: try tsCopy(), to: home, keep: [g.tokens["pending"]!.id], isListening: { _ in false })
    #expect(r.usable == 4 && r.retired == 1)
    let t = await (try Stores(home)).tokens.list().first { $0.id == g.tokens["pending"]!.id }
    #expect(t?.bots.map(\.sessionId) == ["555"])
  }

  @Test("import refuses: a running old gateway, links, a non-empty store, a running new gateway, a busy old lock")
  func refusals() async throws {
    let src = try tsCopy()
    func message(_ body: () async throws -> Void) async -> String {
      do {
        try await body()
        return "no error"
      } catch {
        return String(describing: error)
      }
    }
    #expect(await message { try await TSImport.run(from: src, to: try newHome(), isListening: { $0 == 8787 }) }.contains("listening on port 8787"))
    #expect(await message { try await TSImport.run(from: src, to: try newHome(), isListening: { $0 == 8788 }) }.contains("port 8788"))
    let link = src.deletingLastPathComponent().appendingPathComponent("link-homebot")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: src)
    #expect(await message { try await TSImport.run(from: link, to: try newHome(), isListening: { _ in false }) }.contains("symbolic link"))
    let cfg = src.appendingPathComponent("config.json")
    let real = src.appendingPathComponent("config.real.json")
    try FileManager.default.moveItem(at: cfg, to: real)
    try FileManager.default.createSymbolicLink(at: cfg, withDestinationURL: real)
    #expect(await message { _ = try TSImport.preview(src) }.contains("symbolic link"))
    try FileManager.default.removeItem(at: cfg)
    try FileManager.default.moveItem(at: real, to: cfg)

    let used = try newHome()
    try used.prepare()
    try await (try Stores(used)).lifecycle.add(Bot(key: "x", name: "X", sessionId: "9", strictEcho: true), cursor: "1", maxSeq: "1")
    #expect(await message { try await TSImport.run(from: src, to: used, isListening: { _ in false }) }.contains("import only into a new setup"))

    let owned = try newHome()
    try owned.prepare()
    let lock = try #require(try OwnerLock.tryAcquire(owned.gatewayLock))
    #expect(await message { try await TSImport.run(from: src, to: owned, isListening: { _ in false }) }.contains("quit it before importing"))
    lock.release()

    // A TypeScript command holds config.json's lock: busy. A lock left by a crash is broken.
    let tsLock = src.appendingPathComponent("tokens.json.lock")
    FileManager.default.createFile(atPath: tsLock.path, contents: nil)
    #expect(await message { try await TSImport.run(from: src, to: try newHome(), isListening: { _ in false }) }.contains("busy"))
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: tsLock.path)
    #expect(await message { try await TSImport.run(from: src, to: try newHome(), isListening: { _ in false }) } == "no error")
    #expect(!FileManager.default.fileExists(atPath: src.appendingPathComponent("secrets.json.lock").path))
  }

  @Test("import: a running TypeScript gateway (gateway.pid) is refused; a stale one is not; a failed import leaves both folders retryable")
  func runningAndRollback() async throws {
    let src = try tsCopy()
    let pid = src.appendingPathComponent("gateway.pid")
    try Data("\(getpid())\n".utf8).write(to: pid)
    let home = try newHome()
    await #expect(throws: TSImport.ImportError.self) { try await TSImport.run(from: src, to: home, isListening: { _ in false }) }
    #expect(!FileManager.default.fileExists(atPath: src.appendingPathComponent(TSImport.markerName).path), "the claim is undone")
    try Data("999999\n".utf8).write(to: pid) // no such process
    // A key that can't be saved fails the import after the stores were written.
    let secrets = src.appendingPathComponent("secrets.json")
    let good = try Data(contentsOf: secrets)
    try Data(#"{"bdkApiKey":"two\nlines"}"#.utf8).write(to: secrets)
    await #expect(throws: (any Error).self) { try await TSImport.run(from: src, to: home, isListening: { _ in false }) }
    #expect(!FileManager.default.fileExists(atPath: src.appendingPathComponent(TSImport.markerName).path))
    #expect(await (try Stores(home)).config.bots().isEmpty, "the new store is as it was")
    try good.write(to: secrets)
    let r = try await TSImport.run(from: src, to: home, isListening: { _ in false })
    #expect(r.bots == 2 && r.keyCopied, "the retry works")
  }

  @Test("import keeps a key the app already has; malformed JSON never shows its content")
  func keyAndMalformed() async throws {
    let src = try tsCopy()
    let home = try newHome()
    try home.prepare()
    try Credentials(keyFile: home.apiKey).save(key: "already-saved-not-a-secret")
    let r = try await TSImport.run(from: src, to: home, isListening: { _ in false })
    #expect(!r.keyCopied)
    #expect(try Credentials(keyFile: home.apiKey).savedKey() == "already-saved-not-a-secret")

    let bad = try tsCopy()
    try Data(#"{"bdkApiKey": dummy-secret-value-123}"#.utf8).write(to: bad.appendingPathComponent("secrets.json"))
    let text: String
    do {
      _ = try TSImport.preview(bad)
      text = "no error"
    } catch {
      text = String(describing: error)
    }
    #expect(text.contains("not valid JSON") && !text.contains("dummy"))
  }

  // The e2e parity check: the folder the TypeScript gateway served, imported; the same
  // transcripts in the fake; the same Shortcut-shaped requests in the same order.
  @Test("parity: the Swift gateway gives the TypeScript gateway's answers to the same Shortcut requests")
  func parity() async throws {
    let g = try Golden.load()
    let home = try newHome()
    try await TSImport.run(from: try tsCopy(), to: home, isListening: { _ in false })
    let fake = FakeGrokBot()
    for (sid, entries) in g.transcripts { fake.load(sid, entries) }
    let host = GatewayHost(GatewayOptions(home: home, userHome: home.root, port: 0, bind: "127.0.0.1", bdkBaseURL: FakeGrokBot.baseURL, transport: fake, keepAwake: false, controlSocket: false, traceIdle: .init(maxMs: 0, everyMs: 1000)))
    let port = try await host.start().port
    var lastRun = ""
    for s in g.scenarios {
      if let b = s.bot {
        if b.busy == true {
          fake.setIdle(b.sid, false)
        } else {
          fake.autoReply(b.sid, text: b.text ?? "", echo: b.echo ?? true, more: b.more ?? [])
        }
      }
      let token = s.req.token == "bad" ? "not-a-token" : g.tokens[s.req.token]!.token
      var body: Data?
      if let raw = s.req.raw {
        body = Data(raw.utf8)
      } else if let b = s.req.body {
        var obj = b.any
        if var d = obj as? [String: Any], d["run"] as? String == "$run" {
          d["run"] = lastRun
          obj = d
        }
        body = try JSONSerialization.data(withJSONObject: obj)
      }
      var headers = ["X-Homebot-Token": token]
      if body != nil { headers["Content-Type"] = "application/json" }
      let r = await RawHTTP.send(port: port, method: s.req.method ?? "POST", path: s.req.path ?? "/v1/ask", headers: headers, body: body ?? Data())
      var answer = r.text
      if let m = answer.firstMatch(of: /"run":"([^"]*)"/), !m.1.isEmpty {
        lastRun = String(m.1)
        answer = answer.replacingOccurrences(of: #""run":"\#(m.1)""#, with: #""run":"$run""#)
      }
      #expect(r.status == s.status, "\(s.name)")
      #expect(r.headers["content-type"] == s.contentType, "\(s.name)")
      #expect(answer == s.answer, "\(s.name)")
      if s.bot?.busy == true { fake.setIdle(s.bot!.sid, true) }
      await sleepMs(80)
    }
    await host.stop()
    try? FileManager.default.removeItem(at: home.root.deletingLastPathComponent())
  }
}
