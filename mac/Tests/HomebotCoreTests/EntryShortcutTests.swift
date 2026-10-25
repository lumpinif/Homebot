// The entry Shortcut (DESIGN §20.5, S4): its graph, its golden files, its phrase and its build.
// The golden files are this builder's own output (there is no TypeScript entry Shortcut): they pin
// the graph so a change to it is a visible diff. Regenerate with
// HOMEBOT_WRITE_GOLDEN=1 swift test --filter EntryShortcutTests, then review the diff.
import Foundation
import Testing

@testable import HomebotCore

@Suite("Entry Shortcut (DESIGN §20.5)")
struct EntryShortcutTests {
  static func golden(_ name: String) -> PlistValue {
    let b = counterUUIDs()
    switch name {
    case "entry-en": return try! b.entryShortcut(baseUrl: "http://felix-mac.local:8787/ignored", token: "TOKEN-entry-en", speakLang: "en-US")
    default: return try! b.entryShortcut(baseUrl: "http://felix-mac.local:8787", token: "TOKEN-entry-zh", speakLang: "zh-CN")
    }
  }

  @Test("golden: the entry Shortcut's XML is stable and passes plutil -lint", arguments: ["entry-en", "entry-zh"])
  func goldenFiles(name: String) throws {
    let actual = try Plist.xml(Self.golden(name))
    if ProcessInfo.processInfo.environment["HOMEBOT_WRITE_GOLDEN"] == "1" {
      let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).plist")
      try actual.write(to: src, atomically: true, encoding: .utf8)
    }
    let expected = try #require(String(data: try fixture("\(name).plist"), encoding: .utf8))
    #expect(actual == expected)
    #expect(try plutilLint(actual))
  }

  @Test("graph: the conversation loop with no bot field, posting to /v1/ask, speaking in the Siri language")
  func graph() throws {
    let w = try ShortcutBuilder().entryShortcut(baseUrl: "http://mac.local:8787/x", token: "T", speakLang: "zh-CN")
    let actions = try #require(w["WFWorkflowActions"]?.arrayValue)
    let posts = actions.filter { $0["WFWorkflowActionIdentifier"]?.stringValue == "is.workflow.actions.downloadurl" }.map { $0["WFWorkflowActionParameters"] }
    #expect(posts.count == 2, "step 0 and the loop's step")
    for p in posts {
      #expect(p?["WFURL"]?.stringValue == "http://mac.local:8787/v1/ask")
      let body = dictOf(p?["WFJSONValues"])
      #expect(body["bot"] == nil, "the gateway chooses the bot")
      #expect(body["v"]?["Value"]?["string"]?.stringValue == "2")
      #expect(body["last"]?["Value"]?["string"]?.stringValue == "\(Conversation.steps)")
      #expect(dictOf(p?["WFHTTPHeaders"])["X-Homebot-Token"]?["Value"]?["string"]?.stringValue == "T")
    }
    let speaks = actions.filter { $0["WFWorkflowActionIdentifier"]?.stringValue == "is.workflow.actions.speaktext" }
    #expect(!speaks.isEmpty && speaks.allSatisfy { $0["WFWorkflowActionParameters"]?["WFSpeakTextLanguage"]?.stringValue == "zh-CN" })
    // Same shape as the per-bot conversation Shortcut: the gateway, not the file, holds the policy.
    let conv = try ShortcutBuilder().conversationShortcut(baseUrl: "http://mac.local:8787", botKey: "b", token: "T", prompt: "p", speakLang: "zh-CN")
    #expect(conv["WFWorkflowActions"]?.arrayValue?.map { $0["WFWorkflowActionIdentifier"] } == actions.map { $0["WFWorkflowActionIdentifier"] })
  }

  @Test("phrase: Grok Bot in every language, never a bot name (DECISIONS item 33)")
  func phrase() throws {
    #expect(try Profile.entry(siriLang: "zh-CN").name == "Grok Bot")
    #expect(try Profile.entry(siriLang: "zh-CN").prompt == "想问什么？")
    #expect(try Profile.entry(siriLang: "zh-TW").name == "Grok Bot")
    #expect(try Profile.entry(siriLang: "ja-JP").name == "Grok Bot")
    #expect(try Profile.entry(siriLang: "en-US").name == "Grok Bot")
    #expect(try Profile.entry(siriLang: "zh-CN", taken: ["Grok Bot"]).name == "我的 Grok Bot", "the next unused product phrase")
    let latin = try Profile.entry(siriLang: "zh-CN", name: "Homebot")
    #expect(latin.problems.contains { $0.code == .wrongScript && !$0.blocking }, "a Chinese HomePod may not hear a Latin name (§16.1): advice")
    #expect(try Profile.entry(siriLang: "en-US", name: "Homebot").problems.isEmpty, "English allows Homebot as a phrase")
    for l in Langs.siriOptions.map(\.code) {
      let p = try Profile.entry(siriLang: l)
      #expect(p.problems.isEmpty, "\(l): \(p.name)")
      #expect(!p.prompt.isEmpty)
    }
  }

  @Test("build: one token for the chosen set, mode entry, pending until a bot is pinned")
  func build() async throws {
    let e = try await MakeEnv.make()
    let kitchen = Bot(key: "kitchen", name: "厨房", sessionId: "555", strictEcho: true)
    try await e.stores.lifecycle.add(kitchen, cursor: "1", maxSeq: "1")
    let made = try await ShortcutMaker.make(tokens: e.tokens, lifecycle: e.stores.lifecycle, bots: [chai, kitchen], profile: try Profile.entry(siriLang: "zh-CN"), baseUrl: "http://mac.local:8787", kind: .entry)
    #expect(made.name == "Grok Bot")
    let rec = try #require(await e.tokens.list().first { $0.id == made.tokenId })
    #expect(rec.mode == .entry && rec.state == .pending && (rec.kind ?? .ask) == .ask)
    #expect(rec.bots.map(\.key) == ["chai", "kitchen"])
    let xml = try String(contentsOf: made.file, encoding: .utf8)
    #expect(!xml.contains("<string>bot</string>"))
    #expect(try plutilLint(xml))
    // A one-bot Shortcut can't carry a set; a set is at most 9 bots, each once.
    let two = await errorText { _ = try await ShortcutMaker.make(tokens: e.tokens, lifecycle: e.stores.lifecycle, bots: [chai, kitchen], profile: try Profile.make(botName: "x", name: "Other Name"), baseUrl: "http://mac.local:8787", kind: .ask) }
    #expect(two?.contains("for one bot") == true)
    let twice = await errorText { _ = try await ShortcutMaker.make(tokens: e.tokens, lifecycle: e.stores.lifecycle, bots: [chai, chai], profile: try Profile.entry(siriLang: "zh-CN", name: "我家助手"), baseUrl: "http://mac.local:8787", kind: .entry) }
    #expect(twice?.contains("twice") == true)
    let many = (0..<10).map { Bot(key: "b\($0)", name: "B", sessionId: "\($0 + 100)", strictEcho: true) }
    let tooMany = await errorText { _ = try await ShortcutMaker.make(tokens: e.tokens, lifecycle: nil, bots: many, profile: try Profile.entry(siriLang: "zh-CN", name: "居家助手"), baseUrl: "http://mac.local:8787", kind: .entry) }
    #expect(tooMany?.contains("at most 9") == true)
    #expect(await e.tokens.list().count == 1, "refused builds issue nothing")
  }

  @Test("an entry Shortcut may replace a per-bot one whose bot it covers (T6), never one it would drop")
  func replaces() async throws {
    let e = try await MakeEnv.make()
    let kitchen = Bot(key: "kitchen", name: "厨房", sessionId: "555", strictEcho: true)
    try await e.stores.lifecycle.add(kitchen, cursor: "1", maxSeq: "1")
    let old = try await e.build(try Profile.make(botName: chai.name, siriLang: "zh-CN"))
    let made = try await ShortcutMaker.make(tokens: e.tokens, lifecycle: e.stores.lifecycle, bots: [chai, kitchen], profile: try Profile.entry(siriLang: "zh-CN", keep: old.name), baseUrl: "http://mac.local:8787", kind: .entry, replaces: old.tokenId)
    #expect(made.name == old.name, "a replacement keeps the phrase Siri learned")
    let narrower = await errorText { _ = try await ShortcutMaker.make(tokens: e.tokens, lifecycle: e.stores.lifecycle, bots: [kitchen], profile: try Profile.entry(siriLang: "zh-CN", name: "居家助手"), baseUrl: "http://mac.local:8787", kind: .entry, replaces: made.tokenId) }
    #expect(narrower?.contains("answers for bot") == true)
  }
}
