// Dev mode only (`--dev --dev-seed <level>`): fill the throwaway support folder through the app's
// own actions, against the fake Grok Bot, so every screen can be opened in a known state for
// screenshots and smoke runs. Each level includes the ones before it:
//   key       the fake API key is saved
//   bot       the fake bot "homebot" is added by name
//   shortcut  a Shortcut is made for it (fake signer)
//   activity  that Shortcut asks the running gateway three questions over loopback, so it is
//             active and Home has real activity records
//   entry     a second fake bot, "Kitchen", and a one-phrase Shortcut for both bots
//   shortcuts a Chinese Shortcut, then the Siri language switched back to English (it needs an
//             update), and one more made and revoked: every state on the Shortcuts page
// `--dev-legacy` adds a TypeScript Homebot folder to the dev run's own home folder (never the
// user's ~/.homebot), so the import offer can be tried end to end.
// The key is the fake API's test value, never a real credential.
import CryptoKit
import Foundation
import HomebotCore

public enum DevSeed {
  public enum Level: String, Sendable, Comparable, CaseIterable {
    case none, key, bot, shortcut, activity, entry, shortcuts
    public static func < (a: Level, b: Level) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
  }

  /// The fake Grok Bot API's accepted key (test-helpers/fake-bdk.ts); a test value, not a secret.
  public static let fakeKey = "test-key-not-a-secret"
  public static let fakeBot = "homebot"
  /// The fake API's second bot (scripts/fake-grokbot.ts), for the one-phrase Shortcut.
  public static let fakeBot2 = "Kitchen"

  /// A BDK login for the fake API in the dev run's own home folder, to show the "login found" path.
  public static func writeFakeLogin(userHome: URL) throws {
    let dir = userHome.appendingPathComponent(".config/agent-serve", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let json = #"{"apiKey":"\#(fakeKey)","backendUrl":"https://api.cursor.com"}"#
    try FileUtil.writePrivateFile(dir.appendingPathComponent("credentials.json"), json)
  }

  /// The legacy folder's working Shortcut token, a test value: after the import a request with it
  /// is answered, proving the imported Shortcut keeps working.
  public static let legacyToken = "dev-legacy-token-not-a-secret"

  /// A TypeScript Homebot folder (`~/.homebot` as the TypeScript version writes it) in the dev
  /// run's home folder: the fake API's two bots with their cursors, a working Shortcut, one made
  /// before M4 (no session, kept only if the user chooses), a retired one and the fake key. Its
  /// ports are its own (18927/18928), so the importer's "old gateway still running" check never
  /// looks at the user's real gateway.
  public static func writeLegacyFolder(userHome: URL) throws {
    let dir = userHome.appendingPathComponent(".homebot", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let t = Date().timeIntervalSince1970 * 1000 - 86_400_000
    let config: [String: Any] = [
      "bots": [
        fakeBot: ["name": fakeBot, "sessionId": "14752726", "strictEcho": true],
        "kitchen": ["name": fakeBot2, "sessionId": "555", "strictEcho": true],
      ],
      "settings": ["siriLang": "en-US", "port": 18927, "setupPort": 18928],
    ]
    let state: [String: Any] = ["cursors": [
      fakeBot: ["cursor": "-1", "maxSeq": "0", "syncedAt": t, "sessionId": "14752726"],
    ]]
    let tokens: [String: Any] = ["tokens": [
      ["id": "1e9ac0ffee01", "hash": sha256Hex(legacyToken), "bot": fakeBot, "label": "House Butler", "state": "active", "createdAt": t, "activatedAt": t, "siriLang": "en-US", "sessionId": "14752726"],
      ["id": "1e9ac0ffee02", "hash": sha256Hex("dev-legacy-old-not-a-secret"), "bot": "kitchen", "label": "Kitchen Helper", "state": "active", "createdAt": t, "activatedAt": t, "siriLang": "en-US"],
      ["id": "1e9ac0ffee03", "hash": sha256Hex("dev-legacy-retired-not-a-secret"), "bot": fakeBot, "label": "Ask Homebot", "state": "retired", "createdAt": t, "retiredAt": t, "siriLang": "en-US", "sessionId": "14752726"],
    ]]
    for (name, obj) in [("config.json", config), ("state.json", state), ("tokens.json", tokens), ("secrets.json", ["bdkApiKey": fakeKey] as [String: Any])] {
      try FileUtil.writePrivateFile(dir.appendingPathComponent(name), try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]))
    }
  }

  /// As the TypeScript token store hashes a token.
  static func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  @MainActor
  public static func run(_ m: AppModel, level: Level) async {
    guard m.env.dev else { return }
    await m.refresh()
    if level >= .key, m.snapshot.credential == nil { _ = await m.saveKey(fakeKey) }
    if level >= .bot, m.snapshot.bots.isEmpty { _ = await m.addByName(fakeBot, confirm: fakeBot, strict: true) }
    guard level >= .shortcut, let bot = m.snapshot.bots.first else { return }
    m.markLanguageSeen()
    if !m.snapshot.appleSigning { await m.setLanguages(appleSigning: true, announce: false) }
    guard let made = await m.makeShortcut(ShortcutInput(bot: bot.key), sign: true) else { return }
    guard level >= .activity, let token = token(in: m.builds[made.tokenId]?.file), let port = m.status?.port else { return }
    let siri = m.snapshot.siriLang
    let hant = siri == "zh-TW" || siri == "zh-HK"
    let questions = hant ? ["週末怎麼安排？", "現在幾點？", "明天會下雨嗎？", "給我講個笑話"]
      : siri.hasPrefix("zh") ? ["周末怎么安排？", "现在几点？", "明天会下雨吗？", "给我讲个笑话"]
      : ["Plan my weekend", "What time is it?", "Will it rain tomorrow?", "Tell me a joke"]
    // Yesterday's request that ran out of time: a row with a status and a reason.
    let dayAgo = (Date().timeIntervalSince1970 - 86_400) * 1000
    await m.host.activity.add(ActivityRecord(
      at: dayAgo, durationMs: 9200, replyMs: 3100, tokenId: made.tokenId, label: made.name, mode: "ask", siriLang: siri,
      botKey: bot.key, botName: bot.name, question: hant ? "客廳燈關了嗎？" : siri.hasPrefix("zh") ? "客厅灯关了吗？" : "Are the lights off?",
      outcome: "upstream", reason: "timeout"))
    await m.host.activity.flush()
    for q in questions { await ask(port: port, token: token, bot: bot.key, text: q) }
    if level >= .entry {
      if m.snapshot.bots.count < 2 { _ = await m.addByName(fakeBot2, confirm: fakeBot2, strict: true) }
      _ = await m.makeShortcut(ShortcutInput(bot: "", entry: true, bots: m.snapshot.bots.map(\.key)), sign: true)
    }
    if level >= .shortcuts {
      let english = m.snapshot.siriLang
      await m.setLanguages(siriLang: "zh-CN", announce: false)
      _ = await m.makeShortcut(ShortcutInput(bot: bot.key, name: "居家对话"), sign: true)
      await m.setLanguages(siriLang: english, announce: false)
      if let gone = await m.makeShortcut(ShortcutInput(bot: bot.key, name: "Old Helper"), sign: true) { await m.revoke(gone.tokenId) }
    }
    m.toasts = []
    await m.refresh()
  }

  /// The token inside an unsigned Shortcut file this run built (dev seed only).
  static func token(in file: URL?) -> String? {
    guard let file, let xml = try? String(contentsOf: file, encoding: .utf8),
          let r = xml.range(of: #"X-Homebot-Token</string>[\s\S]*?<key>string</key>\s*<string>([^<]+)</string>"#, options: .regularExpression) else { return nil }
    let m = String(xml[r])
    guard let open = m.range(of: "<string>", options: .backwards), let close = m.range(of: "</string>", options: .backwards) else { return nil }
    return String(m[open.upperBound..<close.lowerBound])
  }

  static func ask(port: Int, token: String, bot: String, text: String) async {
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/ask")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(token, forHTTPHeaderField: "X-Homebot-Token")
    req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "bot": bot])
    req.timeoutInterval = 40
    _ = try? await URLSession.shared.data(for: req)
  }
}
