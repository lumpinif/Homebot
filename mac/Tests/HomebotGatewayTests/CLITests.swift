// The `homebot` command in this process: real stores in a temporary folder, the fake Grok Bot API
// as the transport, `start` on an ephemeral loopback port. Ported from test/server-cli.test.ts and
// the CLI rows of test/shortcut-cli.test.ts. Each command opens its own stores, as a separate
// `homebot` process would, while the gateway keeps its own.
import Foundation
import Testing

@testable import HomebotCLI
@testable import HomebotCore
@testable import HomebotGateway
import HomebotTestSupport

let sid = chai.sessionId

/// The token a built Shortcut carries.
func tokenInShortcut(_ xml: String) -> String? {
  xml.firstMatch(of: /<string>X-Homebot-Token<\/string>[\s\S]*?<key>WFValue<\/key>\s*<dict>\s*<key>Value<\/key>\s*<dict>\s*<key>string<\/key>\s*<string>([^<]+)<\/string>/).map { String($0.1) }
}

func group(_ re: Regex<(Substring, Substring)>, _ s: String) -> String? { s.firstMatch(of: re).map { String($0.1) } }

final class CLIHarness: @unchecked Sendable {
  let dir: URL
  let home: Home
  let fake: FakeGrokBot
  let hosts = Box<[GatewayHost]>([])
  let stdin = Box<String?>(nil)
  let revealed = Box<[String]>([])
  let listening = Box<Set<Int>>([])
  var sign: SignFn?
  var cleanupMs = 10 * 60_000

  init() throws {
    dir = try shortTmpDir()
    home = try Home(root: dir.appendingPathComponent("hb", isDirectory: true))
    fake = FakeGrokBot()
  }

  /// The setup of every server-cli test: a key, the bot `chai` with three old replies, and a
  /// Chinese Siri token for it.
  static func make(settings: SettingsPatch? = nil, sign: SignFn? = nil, cleanupMs: Int? = nil, token: Bool = true) async throws -> (CLIHarness, String) {
    let h = try CLIHarness()
    h.sign = sign
    if let cleanupMs { h.cleanupMs = cleanupMs }
    for i in 0..<3 { h.fake.add(sid, kind: "send-message", text: "old \(i)") }
    h.stdin.value = FakeGrokBot.key
    let k = await h.cli("account", "set-key")
    #expect(k.code == 0, "\(k.text)")
    let a = await h.cli("bot", "add-id", sid, "--key", "chai", "--name", "拆解师")
    #expect(a.code == 0, "\(a.text)")
    if let settings { try await Stores(h.home).config.putSettings(settings) }
    guard token else { return (h, "") }
    let issued = await h.cli("token", "issue", "chai", "--siri-lang", "zh-CN")
    let file = try #require(group(#/written to (\S+) /#, issued.text))
    return (h, try String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
  }

  var io: CLIIO {
    let lines = Box<[String]>([])
    return io(lines)
  }

  func io(_ lines: Box<[String]>) -> CLIIO {
    let hosts = self.hosts
    let stdin = self.stdin
    let revealed = self.revealed
    let listening = self.listening
    return CLIIO(
      out: { s in lines.mutate { $0.append(s) } }, err: { s in lines.mutate { $0.append(s) } },
      userHome: dir, defaultHome: home.root, transport: fake, bdkBaseURL: FakeGrokBot.baseURL,
      readStdin: { stdin.value }, hostName: { "felix-mac" }, sign: sign, reveal: { u in revealed.mutate { $0.append(u.path) } },
      onStarted: { h in hosts.mutate { $0.append(h) } }, probeUnitMs: 5, labUnit: 0.001, cleanupMs: cleanupMs, keepAwake: false,
      isListening: { listening.value.contains($0) })
  }

  @discardableResult
  func cli(_ argv: String...) async -> (code: Int32, text: String) { await cli(argv) }

  func cli(_ argv: [String]) async -> (code: Int32, text: String) {
    let lines = Box<[String]>([])
    let code = await HomebotCLI.run(argv, io: io(lines))
    return (code, lines.value.joined(separator: "\n"))
  }

  /// `homebot start` on an ephemeral loopback port; returns the port.
  func start(_ extra: String...) async throws -> Int {
    let r = await cli(["start", "--port", "0", "--bind", "127.0.0.1"] + extra)
    #expect(r.code == 0, "\(r.text)")
    let host = try #require(hosts.value.last)
    return await host.port
  }

  func stopGateways() async {
    for h in hosts.value { await h.stop() }
    hosts.value = []
  }

  func shortcuts() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: home.shortcuts.path)) ?? []).sorted() }

  func finish() async {
    await stopGateways()
    try? FileManager.default.removeItem(at: dir)
  }
}

func post(_ port: Int, _ token: String, _ body: [String: Any]) async -> RawResponse { await RawHTTP.post(port: port, token: token, body) }

@Suite("homebot command", .serialized)
struct CLITests {
  @Test("end to end: token -> start -> /v1/ask -> owned reply as text/plain; the token is never printed")
  func endToEnd() async throws {
    let (h, token) = try await CLIHarness.make(settings: { var p = SettingsPatch(); p.answerBudgetMs = 2000; p.pollMs = 10; return p }())
    defer { Task { await h.finish() } }
    let port = try await h.start()
    h.fake.autoReply(sid, text: "现在三点。")
    let r = await post(port, token, ["text": "几点了"])
    #expect(r.status == 200)
    #expect(r.headers["content-type"]?.hasPrefix("text/plain") == true)
    #expect(r.text == "现在三点。")
    #expect(h.shortcuts().isEmpty, "the token file is deleted on first use")
    let st = await h.cli("status")
    #expect(st.code == 0)
    #expect(st.text.contains("running on 127.0.0.1:\(port)"))
    #expect(st.text.contains("Last request:") && !st.text.contains(token) && !st.text.contains(FakeGrokBot.key))
    await h.stopGateways()
    #expect(await h.cli("status").code == 1)
  }

  @Test("add-id validates before any network call; no credentials is a clear error")
  func addIdChecks() async throws {
    let (h, _) = try await CLIHarness.make()
    defer { Task { await h.finish() } }
    let before = h.fake.requests.count
    let r = await h.cli("bot", "add-id", "da83afad-uuid", "--key", "x", "--name", "X")
    #expect(r.code == 1)
    #expect(r.text.contains("numeric"))
    #expect(h.fake.requests.count == before)
    let remap = await h.cli("bot", "add-id", "777", "--key", "chai", "--name", "Other")
    #expect(remap.code == 1, "S3: a key is never remapped")
    let reuse = await h.cli("bot", "add-id", sid, "--key", "other", "--name", "Other")
    #expect(reuse.code == 1, "S3: a session is never reused")
    #expect(h.fake.requests.count == before)
    #expect(await h.cli("account", "remove-key").code == 0)
    let noKey = await h.cli("bot", "add-id", "777", "--key", "x", "--name", "X")
    #expect(noKey.code == 1)
    #expect(noKey.text.contains("No Grok Bot credentials found"))
  }

  @Test("start without credentials still runs; a Shortcut request gets the spoken sign-in message")
  func startWithoutKey() async throws {
    let (h, token) = try await CLIHarness.make()
    defer { Task { await h.finish() } }
    #expect(await h.cli("account", "remove-key").code == 0)
    let r = await h.cli("start", "--port", "0", "--bind", "127.0.0.1")
    #expect(r.code == 0, "\(r.text)")
    #expect(r.text.contains("credentials: none yet"))
    #expect(r.text.contains("homebot account set-key"))
    let port = await h.hosts.value[0].port
    let res = await post(port, token, ["text": "hi"])
    #expect(res.text == Messages.of(code: "zh-CN").authFailed)
    #expect(h.fake.posts.isEmpty)
  }

  @Test("doctor reports readable bots without printing secrets; failed add-id leaves no bot")
  func doctor() async throws {
    let (h, token) = try await CLIHarness.make()
    defer { Task { await h.finish() } }
    let d = await h.cli("doctor")
    #expect(d.code == 0, "\(d.text)")
    #expect(d.text.contains("Credentials: saved"))
    #expect(d.text.contains("Bot chai (拆解师): readable, idle"))
    #expect(d.text.contains("Gateway: not running"))
    #expect(!d.text.contains(FakeGrokBot.key) && !d.text.contains(token))
    h.fake.intercept = { _, _, _, _ in .status(401) }
    let bad = await h.cli("bot", "add-id", "555", "--key", "ghost", "--name", "Ghost")
    #expect(bad.code == 1)
    #expect(bad.text.contains("rejected the credentials (401)"))
    #expect(!(await h.cli("bot", "list")).text.contains("ghost"))
    let d2 = await h.cli("doctor")
    #expect(d2.code == 1, "a rejected key fails doctor")
  }

  @Test("preview shows the true latest bot message (not the first page)")
  func preview() async throws {
    let (h, _) = try await CLIHarness.make(token: false)
    defer { Task { await h.finish() } }
    for i in 0..<250 { h.fake.add("777", kind: "send-message", text: "msg \(i)") }
    let r = await h.cli("bot", "add-id", "777", "--key", "big", "--name", "Big", "--preview")
    #expect(r.code == 0, "\(r.text)")
    #expect(r.text.contains("250 entries in 3 page"))
    #expect(r.text.hasSuffix("msg 249"))
  }

  @Test("token export file is 0600 and removed on revoke; token list columns")
  func tokenExport() async throws {
    let (h, _) = try await CLIHarness.make()
    defer { Task { await h.finish() } }
    let files = h.shortcuts()
    #expect(files.count == 1)
    #expect((FileUtil.mode(h.home.shortcuts.appendingPathComponent(files[0])) ?? 0) & 0o777 == 0o600)
    let id = files[0].replacingOccurrences(of: ".token", with: "")
    let list = await h.cli("token", "list")
    #expect(list.text.firstMatch(of: /^\w+\tchai\tpending\t拆解师\tzh-CN\t\d{4}-\d\d-\d\dT[\d:.]+Z$/) != nil, "\(list.text)")
    #expect(await h.cli("token", "revoke", id).code == 0)
    #expect((await h.cli("token", "list")).text.contains("\tretired\t"))
    #expect(h.shortcuts().isEmpty)
    #expect(await h.cli("token", "revoke", "nope").code == 1)
  }

  @Test("S4: a token issued without --siri-lang speaks English; bad languages are rejected")
  func tokenLang() async throws {
    let (h, _) = try await CLIHarness.make(token: false)
    defer { Task { await h.finish() } }
    #expect(await h.cli("token", "issue", "chai").code == 0)
    #expect((await h.cli("token", "list")).text.contains("\ten-US\t"))
    let bad = await h.cli("token", "issue", "chai", "--siri-lang", "xx")
    #expect(bad.code == 1)
    #expect(bad.text.contains("--siri-lang must be one of"))
  }

  // The CLI opens its own stores on the same files: the separate-store path a second `homebot`
  // process takes, under the same locks.
  @Test("B1: a running gateway honours issue/revoke from separate CLI stores and survives a restart")
  func separateStores() async throws {
    let (h, token) = try await CLIHarness.make(settings: { var p = SettingsPatch(); p.answerBudgetMs = 2000; p.pollMs = 10; return p }())
    defer { Task { await h.finish() } }
    var port = try await h.start()
    h.fake.autoReply(sid, text: "OK.") // an English token: its voice reads only Latin (S25)
    #expect(await post(port, token, ["text": "hi"]).status == 200)
    let v1 = try #require(group(/(?m)^(\w+)\tchai\tactive/, (await h.cli("token", "list")).text))
    let issued = await h.cli("token", "issue", "chai", "--replaces", v1)
    let v2file = try #require(group(#/written to (\S+) /#, issued.text))
    let v2token = try String(contentsOfFile: v2file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    h.fake.autoReply(sid, text: "OK.")
    #expect(await post(port, token, ["text": "hi"]).status == 200, "v1 still works while v2 is pending")
    h.fake.autoReply(sid, text: "OK.")
    #expect(await post(port, v2token, ["text": "hi"]).status == 200, "the gateway knows a token issued after it started")
    #expect(await post(port, token, ["text": "hi"]).status == 401, "v1 retired by v2's first use")
    let v2 = try #require(group(/(?m)^(\w+)\tchai\tactive/, (await h.cli("token", "list")).text))
    #expect(await h.cli("token", "revoke", v2).code == 0)
    #expect(await post(port, v2token, ["text": "hi"]).status == 401)
    await h.stopGateways()
    port = try await h.start()
    #expect(await post(port, v2token, ["text": "hi"]).status == 401)
    #expect(await post(port, token, ["text": "hi"]).status == 401)
  }

  @Test("Q-ADD: bot add-name needs --confirm with the exact name; a just-created bot is not added")
  func addName() async throws {
    let (h, _) = try await CLIHarness.make(token: false)
    defer { Task { await h.finish() } }
    h.fake.addNamed("homebot", sid: "4242")
    _ = h.fake.add("4242", kind: "send-message", text: "hi")
    let before = h.fake.requests.count
    let noConfirm = await h.cli("bot", "add-name", "homebot", "--key", "homebot")
    #expect(noConfirm.code == 1)
    #expect(noConfirm.text.contains(#"creates a new empty bot if no bot is named exactly "homebot""#))
    #expect(await h.cli("bot", "add-name", "homebot", "--key", "homebot", "--confirm", "Homebot").code == 1, "case matters")
    #expect(h.fake.requests.count == before, "nothing sent before confirmation")
    let typo = await h.cli("bot", "add-name", "hombot", "--key", "x", "--confirm", "hombot")
    #expect(typo.code == 1)
    #expect(typo.text.contains("just created an empty one") && typo.text.contains("It was not added"))
    #expect(!(await h.cli("bot", "list")).text.contains("hombot"))
    let ok = await h.cli("bot", "add-name", "homebot", "--key", "homebot", "--confirm", "homebot")
    #expect(ok.code == 0, "\(ok.text)")
    #expect(ok.text.contains(#"Added homebot -> "homebot" (session 4242)"#))
    #expect((await h.cli("bot", "list")).text.contains("homebot\thomebot\t4242\tstrict=true\tsynced=yes"))
    #expect(h.fake.posts.isEmpty, "adding never messages a bot")
  }

  @Test("bot remove retires its tokens; token issue --curl-header writes a header file for curl -H @file")
  func removeAndCurlHeader() async throws {
    let (h, token) = try await CLIHarness.make(settings: { var p = SettingsPatch(); p.answerBudgetMs = 2000; p.pollMs = 10; return p }())
    defer { Task { await h.finish() } }
    let issued = await h.cli("token", "issue", "chai", "--siri-lang", "zh-CN", "--label", "M3 curl test", "--curl-header")
    let file = try #require(group(#/written to (\S+) /#, issued.text))
    #expect(file.hasSuffix(".header"))
    #expect((FileUtil.mode(URL(fileURLWithPath: file)) ?? 0) & 0o777 == 0o600)
    let line = try String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let secret = try #require(group(/^X-Homebot-Token: (\S+)$/, line))
    #expect(!issued.text.contains(secret), "the token is never printed")
    let port = try await h.start()
    h.fake.autoReply(sid, text: "现在三点。")
    let res = await post(port, secret, ["text": "几点了", "test": true])
    #expect(res.text == "现在三点。")
    #expect(h.fake.posts.last?.text.firstMatch(of: /^\[Homebot test · hb:[0-9a-f]{12} · zh-CN\]/) != nil, "marked as a test, not a voice request")
    #expect(!h.shortcuts().contains { $0.hasSuffix(".header") }, "header file deleted on first use")
    let removed = await h.cli("bot", "remove", "chai")
    #expect(removed.code == 0)
    #expect(removed.text.contains("Removed chai; 2 Shortcut token(s) retired."))
    #expect(await post(port, token, ["text": "x"]).status == 401)
    #expect(await h.cli("bot", "remove", "chai").code == 1)
    #expect((await h.cli("bot", "list")).text == "")
  }

  @Test("log: through the running gateway, or directly under the owner lock; clear needs --yes")
  func activityLog() async throws {
    let (h, token) = try await CLIHarness.make(settings: { var p = SettingsPatch(); p.answerBudgetMs = 2000; p.pollMs = 10; return p }())
    defer { Task { await h.finish() } }
    #expect((await h.cli("log")).text == "No activity yet.")
    let port = try await h.start()
    h.fake.autoReply(sid, text: "现在三点。")
    #expect(await post(port, token, ["text": "几点了"]).status == 200)
    let live = await h.cli("log")
    #expect(live.code == 0)
    #expect(live.text.contains("\tanswered\t拆解师\t") && live.text.contains(#""几点了" -> "现在三点。""#), "\(live.text)")
    let json = await h.cli("log", "show", "--json", "--limit", "1")
    #expect(json.text.contains(#""outcome":"answered""#) && !json.text.contains(token))
    #expect(await h.cli("log", "clear").code == 1, "clear asks for --yes")
    await h.stopGateways()
    let direct = await h.cli("log")
    #expect(direct.text.contains("几点了"), "read directly when no gateway runs")
    #expect(await h.cli("log", "clear", "--yes").code == 0)
    #expect((await h.cli("log")).text == "No activity yet.")
    // While another process owns the folder but does not answer, nothing is opened directly.
    let lock = try #require(try OwnerLock.tryAcquire(h.home.gatewayLock))
    let busy = await h.cli("log")
    lock.release()
    #expect(busy.code == 1)
    #expect(busy.text.contains("did not answer"))
  }

  @Test("account: set-key reads standard input, status and errors never show the key")
  func account() async throws {
    let (h, _) = try await CLIHarness.make(token: false)
    defer { Task { await h.finish() } }
    let s = await h.cli("account", "status")
    #expect(s.code == 0, "\(s.text)")
    #expect(s.text.contains("Credential: saved") && s.text.contains("Grok Bot: accepted"))
    #expect(!s.text.contains(FakeGrokBot.key))
    h.stdin.value = "  \n"
    #expect(await h.cli("account", "set-key").code == 1)
    h.fake.intercept = { _, _, _, _ in .status(401) }
    h.stdin.value = "another-not-a-secret"
    let rejected = await h.cli("account", "set-key")
    #expect(rejected.code == 1)
    #expect(rejected.text.contains("rejected the key (401)") && !rejected.text.contains("another-not-a-secret"))
    #expect(rejected.text.contains("Make a new key in the Cursor dashboard"), "a rejected key says what to do")
    #expect((FileUtil.mode(h.home.apiKey) ?? 0) & 0o777 == 0o600)
    let removed = await h.cli("account", "remove-key")
    #expect(removed.code == 0)
    #expect(removed.text.contains("No Grok Bot login on this Mac to fall back to"), "\(removed.text)")
    let none = await h.cli("account", "status")
    #expect(none.text.contains("Credential: none") && none.text.contains("the Grok Bot app does not make one"))
  }

  @Test("a key typed as an argument, or in a bot's message, is never printed (Codex S2 review 12, 13)")
  func keyNeverPrinted() async throws {
    let (h, _) = try await CLIHarness.make(token: false)
    defer { Task { await h.finish() } }
    let sentinel = "sk-sentinel-not-a-secret-123"
    let r = await h.cli("account", "set-key", sentinel)
    #expect(r.code == 2)
    #expect(!r.text.contains(sentinel) && r.text.contains("standard input"), "\(r.text)")
    h.fake.add("777", kind: "send-message", text: "your key is \(FakeGrokBot.key) ok")
    let p = await h.cli("bot", "add-id", "777", "--key", "big", "--name", "Big", "--preview")
    #expect(p.code == 0, "\(p.text)")
    #expect(!p.text.contains(FakeGrokBot.key), "\(p.text)")
  }

  @Test("usage errors exit 2, help exits 0; a second start on the same folder is refused")
  func usage() async throws {
    let (h, _) = try await CLIHarness.make(token: false)
    defer { Task { await h.finish() } }
    #expect(await h.cli("bogus").code == 2)
    #expect(await h.cli("token", "issue").code == 2)
    let help = await h.cli("--help")
    #expect(help.code == 0 && help.text.contains("SUBCOMMANDS"))
    _ = try await h.start()
    let second = await h.cli("start", "--port", "0", "--bind", "127.0.0.1")
    #expect(second.code == 1)
    #expect(second.text.contains("already running for this folder"))
  }

  @Test("start refuses a Grok Bot API address other than Cursor's or loopback")
  func baseURL() async throws {
    let (h, _) = try await CLIHarness.make(token: false)
    defer { Task { await h.finish() } }
    var io = h.io
    io.transport = nil
    let lines = Box<[String]>([])
    io.out = { s in lines.mutate { $0.append(s) } }
    io.err = io.out
    let code = await HomebotCLI.run(["start", "--port", "0", "--bind", "127.0.0.1", "--bdk-base-url", "https://evil.example/v0/grokbot/sessions"], io: io)
    #expect(code == 1)
    #expect(lines.value.joined().contains("loopback"))
    #expect(h.hosts.value.isEmpty)
  }

  // MARK: shortcut build (test/shortcut-cli.test.ts)

  @Test("default build: English, Bonjour URL, steps; language defaults come from settings")
  func shortcutDefaults() async throws {
    let (h, _) = try await CLIHarness.make(token: false)
    defer { Task { await h.finish() } }
    let r = await h.cli("shortcut", "build", "chai")
    #expect(r.code == 0, "\(r.text)")
    #expect(r.text.contains(#"Built "Grok Bot" for bot chai (Siri en-US, gateway http://felix-mac.local:8787)."#))
    #expect(r.text.contains("UNSIGNED"))
    #expect(r.text.contains("\n1. "))
    var p = SettingsPatch()
    p.siriLang = "zh-CN"
    p.phoneLang = "zh-Hans"
    try await Stores(h.home).config.putSettings(p)
    let zh = await h.cli("shortcut", "build", "chai")
    #expect(zh.text.contains(#"Built "我的 Grok Bot""#), "the English one still holds Grok Bot: \(zh.text)")
    #expect(zh.text.contains("锁定时允许运行"))
  }

  @Test("built Shortcut's token + request shape are accepted over HTTP; the file is deleted on first use")
  func shortcutOverHTTP() async throws {
    let (h, _) = try await CLIHarness.make(settings: { var p = SettingsPatch(); p.answerBudgetMs = 2000; p.pollMs = 10; return p }(), token: false)
    defer { Task { await h.finish() } }
    let r = await h.cli("shortcut", "build", "chai", "--siri-lang", "zh-CN")
    let file = try #require(group(/File: (.+?\.shortcut) \(/, r.text))
    let token = try #require(tokenInShortcut(try String(contentsOfFile: file, encoding: .utf8)))
    let port = try await h.start()
    h.fake.autoReply(sid, text: "现在三点。")
    let res = await post(port, token, ["bot": "chai", "text": "几点了", "v": "1"]) // exactly what the Shortcut sends
    #expect(res.text == "现在三点。")
    #expect(h.fake.posts.first?.text.contains(" · zh-CN]\n几点了\n") == true)
    #expect(h.shortcuts().isEmpty)
  }

  @Test("signing consent: none without --sign or on a refused build; --sign records it, reveals the signed file")
  func signing() async throws {
    let (h, _) = try await CLIHarness.make(sign: { _, _ in Issue.record("the signer must not run") }, token: false)
    defer { Task { await h.finish() } }
    #expect(await h.cli("shortcut", "build", "chai").code == 0)
    #expect(try await Stores(h.home).config.settings.appleSigning != true)
    #expect(await h.cli("shortcut", "build", "chai", "--sign", "--siri-lang", "zz-ZZ").code == 1)
    #expect(try await Stores(h.home).config.settings.appleSigning != true)
    h.sign = { input, output in try FileManager.default.copyItem(atPath: input, toPath: output) }
    let r = await h.cli("shortcut", "build", "chai", "--sign", "--reveal", "--name", "Kitchen Helper")
    #expect(r.code == 0, "\(r.text)")
    let file = try #require(group(/File: (.+?\.shortcut) \(/, r.text))
    #expect(file.hasSuffix("/Kitchen Helper.shortcut"))
    #expect(r.text.contains("(signed;"))
    #expect(h.revealed.value == [file])
    #expect(try await Stores(h.home).config.settings.appleSigning == true, "--sign records the same consent as the app's Make button")
    h.sign = { _, _ in throw SignError(description: "signing failed after 5 attempts (last exit: 1)") }
    let failed = await h.cli("shortcut", "build", "chai", "--sign", "--name", "Garden Helper")
    #expect(failed.code == 1)
    #expect(failed.text.contains("signing failed"))
  }

  @Test("phrases: a used phrase is refused (repeated spaces are one), a replacement may keep its phrase")
  func phrases() async throws {
    let (h, _) = try await CLIHarness.make(token: false)
    defer { Task { await h.finish() } }
    let first = await h.cli("shortcut", "build", "chai")
    #expect(first.text.contains(#"Built "Grok Bot""#))
    let id = try #require(group(/Token (\w+) is pending/, first.text))
    #expect((await h.cli("shortcut", "build", "chai")).text.contains(#"Built "My Grok Bot""#), "the next unused default")
    let dup = await h.cli("shortcut", "build", "chai", "--name", "grok  bot")
    #expect(dup.code == 1)
    #expect(dup.text.contains("already uses"))
    let repl = await h.cli("shortcut", "build", "chai", "--name", "Grok Bot", "--replaces", id)
    #expect(repl.code == 0, "\(repl.text)")
    #expect(repl.text.contains("and then retires \(id)"))
    for name in ["../../evil:/name", ".hidden"] {
      #expect(await h.cli("shortcut", "build", "chai", "--name", name).code == 1, "\(name)")
    }
    let mixed = await h.cli("shortcut", "build", "chai", "--siri-lang", "zh-CN", "--name", "homebot助手")
    #expect(mixed.code == 0, "\(mixed.text)")
    #expect(mixed.text.contains(#"Note: Siri in this language may not hear "homebot助手""#))
    let brand = await h.cli("shortcut", "build", "chai", "--siri-lang", "zh-CN", "--name", "Grok Bot助手")
    #expect(brand.code == 0 && !brand.text.contains("Note:"), "the brand is fine in a Chinese phrase (DECISIONS item 33): \(brand.text)")
    #expect(await h.cli("shortcut", "build", "chai", "--url", "file:///invalid").code == 1)
    #expect(await h.cli("shortcut", "build", "chai", "--conversation", "--lab").code == 1)
    let looping = await h.cli("shortcut", "build", "chai", "--name", "Our Grok Bot")
    let once = await h.cli("shortcut", "build", "chai", "--no-conversation", "--name", "Chai Once")
    #expect(looping.code == 0 && once.code == 0, "\(looping.text) \(once.text)")
    // On by default (DECISIONS item 36); --no-conversation makes a one-question Shortcut.
    let records = try JSONSerialization.jsonObject(with: Data(contentsOf: h.home.tokens)) as? [String: Any]
    let byLabel = Dictionary(((records?["tokens"] as? [[String: Any]]) ?? []).map { ($0["label"] as? String ?? "", $0["mode"] as? String ?? "") }, uniquingKeysWith: { a, _ in a })
    #expect(byLabel["Our Grok Bot"] == "conversation" && byLabel["Chai Once"] == "single", "\(byLabel)")
  }

  @Test("M2 S2: every CLI run removes artifacts older than 24 h; the token stays pending")
  func cliCleanup() async throws {
    let (h, _) = try await CLIHarness.make(token: false)
    defer { Task { await h.finish() } }
    let r = await h.cli("shortcut", "build", "chai")
    let file = try #require(group(/File: (.+?\.shortcut) \(/, r.text))
    let dir = URL(fileURLWithPath: file).deletingLastPathComponent()
    await h.cli("bot", "list")
    #expect(FileManager.default.fileExists(atPath: dir.path), "fresh: kept")
    let old = Date(timeIntervalSinceNow: -25 * 3600)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.path)
    await h.cli("bot", "list") // any command
    #expect(h.shortcuts().isEmpty)
    #expect((await h.cli("token", "list")).text.contains("\tpending\t"))
  }

  @Test("probe Shortcut + start --probe-wait: the token works, no bot is contacted")
  func probe() async throws {
    let (h, _) = try await CLIHarness.make(token: false)
    defer { Task { await h.finish() } }
    let r = await h.cli("shortcut", "build", "chai", "--probe")
    #expect(r.text.contains(#"Built "Homebot Wait Test""#))
    #expect(r.text.contains(#"run "Homebot Wait Test" once"#))
    let file = try #require(group(/File: (.+?\.shortcut) \(/, r.text))
    let token = try #require(tokenInShortcut(try String(contentsOfFile: file, encoding: .utf8)))
    let started = await h.cli("start", "--port", "0", "--bind", "127.0.0.1", "--probe-wait")
    #expect(started.text.contains("Wait-limit probe enabled"))
    let port = await h.hosts.value[0].port
    let res = await RawHTTP.get(port: port, path: "/v1/probe-wait", token: token)
    #expect(res.text == "Waited 5 seconds.")
    #expect(h.fake.posts.isEmpty)
  }

  @Test("lab: build the lab Shortcut, choose an experiment, run it over HTTP, read the report")
  func lab() async throws {
    let (h, _) = try await CLIHarness.make(token: false)
    defer { Task { await h.finish() } }
    let b = await h.cli("shortcut", "build", "chai", "--lab", "--siri-lang", "zh-CN")
    #expect(b.code == 0, "\(b.text)")
    #expect(b.text.contains(#"Built "家庭实验""#))
    let file = try #require(group(/File: (.+?\.shortcut) \(/, b.text))
    let token = try #require(tokenInShortcut(try String(contentsOfFile: file, encoding: .utf8)))
    let twice = await h.cli("shortcut", "build", "chai", "--lab", "--siri-lang", "zh-CN")
    #expect(twice.code == 1, "a second lab Shortcut would share its phrase")
    #expect(await h.cli("lab", "use", "E9").code == 1)
    #expect(await h.cli("lab", "use", "E7", "--delays", "0").code == 1)
    #expect((await h.cli("lab", "use", "E2")).text.contains("now runs E2"))
    let started = await h.cli("start", "--port", "0", "--bind", "127.0.0.1", "--lab")
    #expect(started.text.contains("Lab enabled at /v1/lab, experiment E2"), "\(started.text)")
    let port = await h.hosts.value[0].port
    let s0 = await RawHTTP.post(port: port, path: "/v1/lab", token: token, ["v": "2", "step": "0", "run": "", "last": "10", "text": ""])
    let run = try #require(s0.json["run"] as? String)
    _ = await RawHTTP.post(port: port, path: "/v1/lab", token: token, ["v": "2", "step": "1", "run": run, "last": "10", "text": "明天我想去公园散步"])
    var report = ""
    for _ in 0..<50 where !report.contains("\tcut\t") {
      report = (await h.cli("lab", "report")).text
      await sleepMs(10)
    }
    #expect(report.firstMatch(of: /\tE2\t[0-9a-f]{6}\t1\tv1\t9\tcut\t/) != nil, "\(report)")
    #expect(!report.contains("公园"), "no speech text in the report")
    #expect(h.fake.posts.isEmpty)
  }

  @Test("shortcut build --entry --bots: one phrase for a set; aliases, set edits and same-sound warnings")
  func entryBuild() async throws {
    let (h, _) = try await CLIHarness.make(token: false)
    defer { Task { await h.finish() } }
    h.fake.add("555", kind: "send-message", text: "old")
    #expect(await h.cli("bot", "add-id", "555", "--key", "kitchen", "--name", "厨房").code == 0)
    #expect(await h.cli("shortcut", "build", "--bots", "chai").code == 1, "--bots goes with --entry")
    #expect(await h.cli("shortcut", "build", "chai", "--entry").code == 1, "the bots are named with --bots")
    #expect(await h.cli("shortcut", "build", "--entry", "--bots", "chai,nope").code == 1)
    let r = await h.cli("shortcut", "build", "--entry", "--bots", "chai,kitchen", "--siri-lang", "zh-CN")
    #expect(r.code == 0, "\(r.text)")
    #expect(r.text.contains(#"Built "Grok Bot" for bots chai, kitchen (Siri zh-CN"#), "\(r.text)")
    #expect(r.text.contains("Siri: 问哪个机器人？1 拆解师，2 厨房。 / You: 拆解师 / Siri: 拆解师。想问什么？"), "\(r.text)")
    #expect(r.text.contains("not been tried on a HomePod"))
    let id = try #require(group(/Token ([0-9a-f]{12}) is pending/, r.text))
    let file = try #require(group(/File: (.+?\.shortcut) \(/, r.text))
    #expect(!(try String(contentsOfFile: file, encoding: .utf8)).contains("<string>bot</string>"))
    let listed = await h.cli("token", "list")
    #expect(listed.text.contains("\(id)\tchai,kitchen\tpending\tGrok Bot"), "\(listed.text)")
    // A second bot with the same sound as an existing one can only be chosen by number.
    h.fake.add("888", kind: "send-message", text: "old")
    #expect(await h.cli("bot", "add-id", "888", "--key", "chu", "--name", "出房").code == 0)
    let edit = await h.cli("token", "bots", id, "chai,kitchen,chu")
    #expect(edit.code == 0, "\(edit.text)")
    #expect(!edit.text.contains("only be chosen"), "same sound is a close match, asked back; only same-text names are by number")
    #expect(await h.cli("token", "bots", id, "").code == 1, "never empty: revoke instead")
    let alias = await h.cli("bot", "alias", "kitchen", "拆解师")
    #expect(alias.code == 0)
    #expect(alias.text.contains("\"拆解师\" can only be chosen by its number"), "\(alias.text)")
    #expect((await h.cli("bot", "list")).text.contains("aliases=拆解师"))
    #expect(await h.cli("bot", "alias", "kitchen").code == 0, "no names: cleared")
    #expect(!(await h.cli("bot", "list")).text.contains("aliases="))
    #expect(await h.cli("bot", "alias", "nope", "x").code == 1)
    // Default: every bot (at most 9); the next unused product phrase.
    let all = await h.cli("shortcut", "build", "--entry", "--siri-lang", "zh-CN")
    #expect(all.text.contains(#"Built "我的 Grok Bot" for bots chai, chu, kitchen"#), "\(all.text)")
  }

  @Test("reset: says what goes without --yes, refuses while a gateway runs, then a used Shortcut stops working")
  func reset() async throws {
    let (h, token) = try await CLIHarness.make()
    defer { Task { await h.finish() } }
    // An orphan Shortcut file, which any other command's 24 h cleanup would delete.
    let orphan = h.home.shortcuts.appendingPathComponent("0123456789ab.shortcut")
    try FileUtil.writePrivateFile(orphan, Data("x".utf8))
    let dry = await h.cli("reset")
    #expect(FileManager.default.fileExists(atPath: orphan.path), "the preview changes nothing")
    #expect(dry.code == 1)
    #expect(dry.text.contains("1 bot(s), 1 Shortcut token(s)") && dry.text.contains("--yes"), "\(dry.text)")
    #expect(try await Stores(h.home).config.bots().count == 1, "nothing changes without --yes")

    _ = try await h.start()
    let running = await h.cli("reset", "--yes")
    #expect(running.code == 1)
    #expect(running.text.contains("quit it first"), "\(running.text)")
    await h.stopGateways()

    let done = await h.cli("reset", "--yes")
    #expect(done.code == 0, "\(done.text)")
    #expect(done.text.contains("removed 1 bot(s) and 1 Shortcut token(s)") && done.text.contains("Credential now: saved"), "\(done.text)")
    #expect(!done.text.contains(token) && !done.text.contains(FakeGrokBot.key))
    #expect(h.shortcuts().isEmpty)
    let port = try await h.start()
    let r = await post(port, token, ["text": "几点了"])
    #expect(r.status == 401, "the old Shortcut's token is unknown now")
    await h.stopGateways()

    let key = await h.cli("reset", "--remove-key", "--yes")
    #expect(key.code == 0)
    #expect(key.text.contains("and the saved API key") && key.text.contains("Credential now: none"), "\(key.text)")
  }
}
