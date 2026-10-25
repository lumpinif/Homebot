// First run (S5): the import of the TypeScript version's folder is offered, never automatic, and
// once clicked brings its Shortcuts over working; where the app runs from (Applications,
// translocated, elsewhere) and the login item refusal while translocated; the Mac card's state.
import Foundation
import Testing

import HomebotCore
import HomebotGateway
import HomebotTestSupport
@testable import HomebotUI

@MainActor
private func model(_ fake: FakeGrokBot, legacy: Bool = true, _ edit: (inout AppEnv) -> Void = { _ in }) async throws -> AppModel {
  let root = try shortDir()
  var env = AppEnv()
  env.home = root.appendingPathComponent("hb", isDirectory: true)
  env.userHome = root
  env.port = 0
  env.bind = "127.0.0.1"
  env.bdkBaseURL = FakeGrokBot.baseURL
  env.transport = fake
  env.sign = { i, o in try FileManager.default.copyItem(atPath: i, toPath: o) }
  env.fakeLoginItem = true
  env.placement = .applications
  edit(&env)
  if legacy { try DevSeed.writeLegacyFolder(userHome: root) }
  let home = try Home(root: env.home)
  try home.prepare()
  var prefs = AppPrefs()
  prefs.keepAwake = false
  try prefs.save(home)
  let m = try AppModel(env: env)
  m.lookForLegacy()
  await m.startGateway()
  await m.refresh()
  return m
}

/// Something listening on 127.0.0.1:port, as the old gateway would.
private final class Listener {
  let fd: Int32
  init?(port: Int) {
    fd = socket(AF_INET, SOCK_STREAM, 0)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard bound == 0, listen(fd, 4) == 0 else {
      close(fd)
      return nil
    }
  }
  deinit { close(fd) }
}

private func ask(port: Int, token: String, text: String) async throws -> (Int, String) {
  var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/ask")!)
  req.httpMethod = "POST"
  req.setValue("application/json", forHTTPHeaderField: "Content-Type")
  req.setValue(token, forHTTPHeaderField: "X-Homebot-Token")
  req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
  let (data, resp) = try await URLSession.shared.data(for: req)
  return ((resp as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
}

@MainActor
@Suite(.serialized) struct FirstRunTests {
  @Test("the earlier version's folder is offered, and nothing is imported until the user clicks")
  func offered() async throws {
    let m = try await model(FakeGrokBot())
    defer { Task { await m.shutdown() } }
    #expect(m.offersImport)
    #expect(m.legacy?.bots.count == 2)
    #expect(m.legacy?.hasKey == true)
    #expect(m.legacyFolderName == "~/.homebot")
    #expect(m.snapshot.bots.isEmpty && m.snapshot.tokens.isEmpty)
    #expect(m.snapshot.credential == nil, "the old key is not used before the import")
    #expect(!FileManager.default.fileExists(atPath: m.legacyFolder.appendingPathComponent(TSImport.markerName).path))
  }

  @Test("Import brings the setup over: the old Shortcut is answered, the folder is marked as moved")
  func imports() async throws {
    let fake = FakeGrokBot()
    fake.addNamed(DevSeed.fakeBot, sid: "14752726")
    fake.addNamed(DevSeed.fakeBot2, sid: "555")
    fake.autoReply("14752726", text: "It's three.")
    let m = try await model(fake)
    defer { Task { await m.shutdown() } }
    let sessionless = try #require(m.legacy?.tokens.first { $0.sessionless })
    m.importKeep = [sessionless.id]
    #expect(await m.importLegacy())
    #expect(m.status?.running == true, "the gateway runs again on the imported stores")
    #expect(m.legacy == nil && !m.offersImport && !m.canImport)
    #expect(Set(m.snapshot.bots.map(\.key)) == [DevSeed.fakeBot, "kitchen"])
    #expect(m.snapshot.liveTokens.count == 2, "the working Shortcut and the kept one")
    #expect(m.snapshot.credential?.source == .saved, "the old key was copied once")
    #expect(FileManager.default.fileExists(atPath: m.legacyFolder.appendingPathComponent(TSImport.markerName).path))
    #expect(m.toasts.last?.text == m.tr.fmt(m.tr.importDone, ["bots": "2", "shortcuts": "2"]))
    let port = try #require(m.status?.port)
    let (status, said) = try await ask(port: port, token: DevSeed.legacyToken, text: "What time is it?")
    #expect(status == 200)
    #expect(said == "It's three.")
    await m.refresh()
    #expect(m.activity.first?.outcome == "answered", "a Shortcut made by the old version keeps working")
    #expect(m.page == .home)
  }

  @Test("a sessionless Shortcut not kept is imported retired")
  func notKept() async throws {
    let m = try await model(FakeGrokBot())
    defer { Task { await m.shutdown() } }
    #expect(await m.importLegacy())
    #expect(m.snapshot.liveTokens.count == 1)
  }

  @Test("while the old gateway runs, the import refuses, changes nothing and the gateway comes back")
  func oldGatewayRunning() async throws {
    let m = try await model(FakeGrokBot())
    defer { Task { await m.shutdown() } }
    let old = try #require(Listener(port: 18927), "port 18927 is free for the test")
    #expect(await m.importLegacy() == false)
    #expect(m.toasts.last?.text == m.tr.importRunning)
    #expect(m.status?.running == true)
    #expect(m.snapshot.bots.isEmpty)
    #expect(m.offersImport, "still offered for the next try")
    #expect(!FileManager.default.fileExists(atPath: m.legacyFolder.appendingPathComponent(TSImport.markerName).path))
    withExtendedLifetime(old) {}
  }

  @Test("Not now hides the offer; Settings still offers it; a used setup is never offered one")
  func dismissed() async throws {
    let m = try await model(FakeGrokBot())
    defer { Task { await m.shutdown() } }
    m.dismissImport()
    #expect(!m.offersImport && m.canImport)
    #expect(AppPrefs.load(m.home).importDismissed)
    let fake = FakeGrokBot()
    fake.addNamed("homebot", sid: "14752726")
    let used = try await model(fake)
    defer { Task { await used.shutdown() } }
    _ = await used.saveKey(FakeGrokBot.key)
    #expect(await used.addByName("homebot", confirm: "homebot", strict: true))
    #expect(!used.canImport, "the importer copies only into a new setup")
  }

  @Test("no folder, or one already moved: nothing is offered")
  func nothingToOffer() async throws {
    let none = try await model(FakeGrokBot(), legacy: false)
    defer { Task { await none.shutdown() } }
    #expect(none.legacy == nil && !none.offersImport)
    let moved = try await model(FakeGrokBot())
    defer { Task { await moved.shutdown() } }
    try Data("{}".utf8).write(to: moved.legacyFolder.appendingPathComponent(TSImport.markerName))
    moved.lookForLegacy()
    #expect(!moved.offersImport)
  }

  @Test("after the import Grok Bot is asked about the key: a rejected one is said, not \"imported\"")
  func importChecksKey() async throws {
    let fake = FakeGrokBot()
    fake.addNamed(DevSeed.fakeBot, sid: "14752726")
    let m = try await model(fake)
    defer { Task { await m.shutdown() } }
    // The old folder holds a key Grok Bot no longer accepts.
    let secrets = m.legacyFolder.appendingPathComponent("secrets.json")
    try FileUtil.writePrivateFile(secrets, try JSONSerialization.data(withJSONObject: ["bdkApiKey": "revoked-key-not-a-secret"]))
    #expect(await m.importLegacy())
    #expect(m.snapshot.credential?.access == .rejected)
    #expect(m.toasts.last?.text == m.tr["errors.auth"])
    #expect(m.toasts.last?.kind == .error)
  }

  @Test("when the gateway can't start again after the import, the import doesn't claim Siri works")
  func importGatewayDown() async throws {
    let busy = try #require(Listener(port: 18929), "port 18929 is free for the test")
    let m = try await model(FakeGrokBot()) { $0.port = 18929 }
    defer { Task { await m.shutdown() } }
    #expect(m.startFailed)
    #expect(await m.importLegacy())
    #expect(m.startFailed && m.status?.running != true)
    #expect(m.toasts.last?.text == m.tr.importNoGateway)
    withExtendedLifetime(busy) {}
  }

  @Test("Quit while importing waits for the import to finish")
  func quitDuringImport() async throws {
    let m = try await model(FakeGrokBot())
    let marker = m.legacyFolder.appendingPathComponent(TSImport.markerName)
    let importing = Task { await m.importLegacy() }
    for _ in 0..<1000 where !m.importing { await Task.yield() }
    #expect(m.importing, "the import has started")
    await m.shutdown()
    #expect(!m.importing, "shutdown returned only after the import")
    #expect(await importing.value)
    let text = try String(contentsOf: marker, encoding: .utf8)
    #expect(!text.contains("\"importing\":true"), "the marker is the finished one, not the one written while importing")
  }

  @Test("in dev mode the importer never probes the user's own gateway ports")
  func devReservedPorts() async throws {
    let m = try await model(FakeGrokBot()) { $0.dev = true }
    defer { Task { await m.shutdown() } }
    let config = m.legacyFolder.appendingPathComponent("config.json")
    var obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
    obj["settings"] = ["siriLang": "en-US"]
    try FileUtil.writePrivateFile(config, try JSONSerialization.data(withJSONObject: obj))
    #expect(await m.importLegacy() == false, "the default ports 8787/8788 count as a running old gateway")
    #expect(m.toasts.last?.text == m.tr.importRunning)
    #expect(m.snapshot.bots.isEmpty)
  }

  @Test("Settings' Import shows the import card again, with its choices")
  func settingsReviews() async throws {
    let m = try await model(FakeGrokBot())
    defer { Task { await m.shutdown() } }
    m.dismissImport()
    #expect(!m.offersImport)
    m.reviewImport()
    #expect(m.offersImport && m.snapshot.bots.isEmpty, "shown, nothing imported")
    #expect(!AppPrefs.load(m.home).importDismissed)
  }

  @Test("a dev folder whose user/.homebot is a link is refused before anything is written")
  func devLegacyLink() throws {
    let root = try shortDir()
    let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    let dev = root.appendingPathComponent("dev", isDirectory: true)
    try FileManager.default.createDirectory(at: dev.appendingPathComponent("user"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: dev.appendingPathComponent("user/.homebot"), withDestinationURL: elsewhere)
    #expect(throws: AppEnv.UsageError.self) { try AppEnv.parse(["--dev", "--dev-home", dev.path, "--dev-legacy"]) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
  }

  @Test("where the app runs from")
  func placement() {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    #expect(AppPlacement.of(URL(fileURLWithPath: "/Applications/Homebot.app"), userHome: home) == .applications)
    #expect(AppPlacement.of(URL(fileURLWithPath: "/Users/someone/Applications/Homebot.app"), userHome: home) == .applications)
    #expect(AppPlacement.of(URL(fileURLWithPath: "/private/var/folders/xy/abc/T/AppTranslocation/5A1B/d/Homebot.app"), userHome: home) == .translocated)
    #expect(AppPlacement.of(URL(fileURLWithPath: "/Users/someone/Downloads/Homebot.app"), userHome: home) == .elsewhere)
    #expect(AppPlacement.of(URL(fileURLWithPath: "/Applications Old/Homebot.app"), userHome: home) == .elsewhere)
  }

  @Test("translocated: Open at login is refused and says why")
  func translocatedLogin() async throws {
    let m = try await model(FakeGrokBot(), legacy: false) { $0.placement = .translocated }
    defer { Task { await m.shutdown() } }
    m.setLoginItem(true)
    #expect(m.loginItemError == .translocated)
    #expect(m.loginItem == .off)
  }

  @Test("the Mac card stays closed once done")
  func macCard() async throws {
    let m = try await model(FakeGrokBot(), legacy: false)
    defer { Task { await m.shutdown() } }
    #expect(!m.prefs.macHintsDone)
    m.finishMacHints()
    #expect(AppPrefs.load(m.home).macHintsDone)
  }

  @Test("--dev-legacy writes the folder into the dev run's own home; placement needs --dev")
  func devFlags() throws {
    let e = try AppEnv.parse(["--dev", "--dev-legacy", "--dev-placement", "translocated"])
    #expect(e.placement == .translocated)
    #expect(FileManager.default.fileExists(atPath: e.userHome.appendingPathComponent(".homebot/tokens.json").path))
    #expect(e.userHome.path != FileManager.default.homeDirectoryForCurrentUser.path)
    #expect(try AppEnv.parse(["--dev"]).placement == .applications, "dev runs from a build folder count as Applications")
    #expect(throws: AppEnv.UsageError.self) { try AppEnv.parse(["--dev-placement", "elsewhere"]) }
    #expect(throws: AppEnv.UsageError.self) { try AppEnv.parse(["--dev-legacy"]) }
  }
}
