// Reset everything: the support folder back to a first run, through the stores and their locks;
// the saved key only on request; nothing outside the folder; refused while a gateway owns it.
import Foundation
import Testing

@testable import HomebotCore
import HomebotTestSupport

@Suite("Reset")
struct ResetTests {
  /// A folder with a bot, its cursor, two tokens (one with a built file), activity, logs, the lab
  /// state, app preferences and a saved key.
  func filled() async throws -> (Home, URL) {
    let dir = try tmpDir()
    let home = try Home(root: dir.appendingPathComponent("hb", isDirectory: true))
    try home.prepare()
    let config = try await ConfigStore(file: home.config).load()
    let state = try await StateStore(file: home.state).load()
    let tokens = try await TokenStore(file: home.tokens, artifactsDir: home.shortcuts).load()
    let life = BotLifecycle(config: config, state: state, tokens: tokens)
    try await life.add(Bot(key: "chai", name: "拆解师", sessionId: "14752726", strictEcho: true), cursor: "5", maxSeq: "5")
    var p = SettingsPatch()
    p.siriLang = "zh-CN"
    try await config.putSettings(p)
    let a = try await tokens.issue(bots: [BotGrant(key: "chai", sessionId: "14752726")], label: "问拆解师")
    _ = try await tokens.issue(bots: [BotGrant(key: "chai", sessionId: "14752726")], label: "家庭助手")
    try FileUtil.writePrivateFile(try tokens.artifactPath(a.id, ext: "shortcut"), Data("x".utf8))
    let activity = ActivityStore(dir: home.activity)
    try await activity.open()
    await activity.add(ActivityRecord(at: 1, durationMs: 1, tokenId: a.id, label: "问拆解师", mode: "single", siriLang: "zh-CN", botKey: "chai", botName: "拆解师", question: "q", spoken: "s", outcome: "answered"))
    await activity.flush()
    await activity.close()
    await JSONLLogger(dir: home.logs).write(["event": "test"])
    try FileUtil.writePrivateFile(home.lab, Data("{}".utf8))
    try FileUtil.writePrivateFile(home.usage, Data("{}".utf8))
    try FileUtil.writePrivateFile(home.root.appendingPathComponent("app.json"), Data(#"{"languageSeen":true}"#.utf8))
    try Credentials(keyFile: home.apiKey, userHome: dir).save(key: "test-key-12345678")
    // Something next to the folder, which a reset must never touch.
    try FileUtil.writePrivateFile(dir.appendingPathComponent("outside.txt"), Data("keep".utf8))
    return (home, dir)
  }

  @Test("everything in the folder goes, the key stays unless asked; nothing outside is touched")
  func resetsToFirstRun() async throws {
    let (home, dir) = try await filled()
    defer { try? FileManager.default.removeItem(at: dir) }
    let r = try await Reset.run(home, removeKey: false, userHome: dir)
    #expect(r == Reset.Report(bots: 1, shortcuts: 2, keyRemoved: false))

    let config = try await ConfigStore(file: home.config).load()
    #expect(await config.bots().isEmpty)
    #expect(await config.settings == Settings(SettingsPatch()), "settings are back to their defaults")
    #expect(try await StateStore(file: home.state).load().cursor("chai") == nil)
    #expect(try await TokenStore(file: home.tokens).load().list().isEmpty, "token records are deleted, not only retired")
    let fm = FileManager.default
    #expect(try fm.contentsOfDirectory(atPath: home.shortcuts.path).isEmpty)
    #expect(try fm.contentsOfDirectory(atPath: home.logs.path).allSatisfy { $0.hasSuffix(".lock") })
    #expect(!fm.fileExists(atPath: ActivityStore(dir: home.activity).file.path))
    #expect(!fm.fileExists(atPath: home.lab.path))
    #expect(!fm.fileExists(atPath: home.usage.path))
    #expect(!fm.fileExists(atPath: home.root.appendingPathComponent("app.json").path))
    #expect(try Credentials(keyFile: home.apiKey, userHome: dir).savedKey() == "test-key-12345678")
    #expect(fm.fileExists(atPath: dir.appendingPathComponent("outside.txt").path))

    // A fresh activity database opens on the empty folder.
    let activity = ActivityStore(dir: home.activity)
    try await activity.open()
    #expect(try await activity.recent().isEmpty)
    await activity.close()

    let again = try await Reset.run(home, removeKey: true, userHome: dir)
    #expect(again == Reset.Report(bots: 0, shortcuts: 0, keyRemoved: true))
    #expect(try Credentials(keyFile: home.apiKey, userHome: dir).savedKey() == nil)
  }

  @Test("refused, with nothing changed, while a gateway owns the folder")
  func refusedWhileRunning() async throws {
    let (home, dir) = try await filled()
    defer { try? FileManager.default.removeItem(at: dir) }
    let owner = try #require(try OwnerLock.tryAcquire(home.gatewayLock))
    defer { owner.release() }
    await #expect(throws: Reset.ResetError.self) { try await Reset.run(home, removeKey: true, userHome: dir) }
    #expect(try await ConfigStore(file: home.config).load().bots().count == 1)
    #expect(try await TokenStore(file: home.tokens).load().list().count == 2)
    #expect(try Credentials(keyFile: home.apiKey, userHome: dir).savedKey() != nil)
  }

  @Test("a link in the Shortcuts folder is deleted, never what it points to")
  func linksAreNotFollowed() async throws {
    let (home, dir) = try await filled()
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("outside.txt")
    try FileManager.default.createSymbolicLink(at: home.shortcuts.appendingPathComponent("link"), withDestinationURL: target)
    try await Reset.run(home, removeKey: false, userHome: dir)
    #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
    #expect(try FileManager.default.contentsOfDirectory(atPath: home.shortcuts.path).isEmpty)
  }

  @Test("a linked Logs or Shortcuts folder is refused before anything changes (Codex S19 review)")
  func linkedFolderRefused() async throws {
    for name in ["Logs", "Shortcuts"] {
      let (home, dir) = try await filled()
      defer { try? FileManager.default.removeItem(at: dir) }
      let elsewhere = dir.appendingPathComponent("elsewhere", isDirectory: true)
      try FileUtil.ensurePrivateDir(elsewhere)
      try FileUtil.writePrivateFile(elsewhere.appendingPathComponent("precious"), Data("keep".utf8))
      let folder = home.root.appendingPathComponent(name, isDirectory: true)
      try FileManager.default.removeItem(at: folder)
      try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: elsewhere)
      await #expect(throws: Reset.ResetError.self) { try await Reset.run(home, removeKey: true, userHome: dir) }
      #expect(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("precious").path), "\(name)")
      #expect(try await ConfigStore(file: home.config).load().bots().count == 1, "nothing was reset")
    }
  }

  @Test("damaged store files are reset too, not left half done (Codex S19 review)")
  func damagedStores() async throws {
    let (home, dir) = try await filled()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileUtil.writePrivateFile(home.state, Data("{not json".utf8))
    try FileUtil.writePrivateFile(home.tokens, Data("[".utf8))
    let r = try await Reset.run(home, removeKey: true, userHome: dir)
    #expect(r == Reset.Report(bots: 1, shortcuts: 0, keyRemoved: true))
    #expect(try await ConfigStore(file: home.config).load().bots().isEmpty)
    #expect(try await StateStore(file: home.state).load().cursor("chai") == nil)
    #expect(try await TokenStore(file: home.tokens).load().list().isEmpty)
  }

  @Test("a check still out for the kept key is ignored after a reset")
  func credentialStatusForgets() async {
    let s = CredentialStatus()
    let c = Credential(key: "test-key-12345678", source: .saved)
    let g = await s.observe(c)
    #expect(await s.record(generation: g, accepted: true))
    await s.reset()
    #expect(await s.state == .unchecked)
    #expect(await s.record(generation: g, accepted: true) == false)
    let g2 = await s.observe(c)
    let state = await s.state
    #expect(g2 != g && state == .unchecked, "the same key starts unchecked again")
  }
}
