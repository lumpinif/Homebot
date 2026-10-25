// The Swift port against the TypeScript output for the same inputs (scripts/swift-golden.ts):
// Shortcut XML byte for byte, and every spoken catalog, envelope, phrase rule and speech result.
import Foundation
import Testing

@testable import HomebotCore

@Suite("Golden: TypeScript parity")
struct GoldenTests {
  nonisolated(unsafe) static let golden: [String: Any] = {
    let data = (try? fixture("ts-golden.json")) ?? Data()
    return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
  }()

  @Test("Shortcut XML is byte-for-byte the TypeScript builder's", arguments: [
    "ask-en", "ask-zh", "ask-escaping", "probe-en", "lab-zh", "conversation-zh", "conversation-ja",
  ])
  func shortcutBytes(name: String) throws {
    let b = counterUUIDs()
    let plist: PlistValue
    switch name {
    case "ask-en": plist = try b.askShortcut(baseUrl: "http://felix-mac.local:8787/ignored", botKey: "chai", token: "TOKEN-en", prompt: "What would you like to ask Chai?", speakLang: "en-US")
    case "ask-zh": plist = try b.askShortcut(baseUrl: "http://felix-mac.local:8787", botKey: "homebot", token: "TOKEN-zh", prompt: "想问拆解师什么？", speakLang: "zh-CN")
    case "ask-escaping": plist = try b.askShortcut(baseUrl: "https://192.168.1.20:8787", botKey: "kitchen-bot", token: "a&b<c>d\"e'f", prompt: "Q & <A> \"quoted\" 'single' é 😀", speakLang: "fr-FR")
    case "probe-en": plist = try b.probeShortcut(baseUrl: "http://mac.local:8787", token: "TOKEN-probe", speakLang: "en-GB")
    case "lab-zh": plist = try b.labShortcut(baseUrl: "http://mac.local:8787/x", token: "TOKEN-lab", speakLang: "zh-CN")
    case "conversation-zh": plist = try b.conversationShortcut(baseUrl: "http://felix-mac.local:8787", botKey: "chai", token: "TOKEN-conv", prompt: "想问拆解师什么？", speakLang: "zh-CN")
    default: plist = try b.conversationShortcut(baseUrl: "http://mac.local:80", botKey: "b", token: "T", prompt: "何を聞きますか？", speakLang: "ja-JP")
    }
    let expected = try #require(String(data: try fixture("\(name).plist"), encoding: .utf8))
    let actual = try Plist.xml(plist)
    #expect(actual == expected)
  }

  static func messageDict(_ m: Messages, bot: String) -> [String: String] {
    [
      "busy": m.busy(bot), "inFlight": m.inFlight(bot), "notSent": m.notSent, "noReplyInTime": m.noReplyInTime(bot), "refused": m.refused,
      "unspeakable": m.unspeakable, "wrongScript": m.wrongScript, "emptyQuestion": m.emptyQuestion, "tooLong": m.tooLong, "badToken": m.badToken, "forbiddenBot": m.forbiddenBot,
      "botNotConfigured": m.botNotConfigured, "authFailed": m.authFailed, "upstreamDown": m.upstreamDown, "rateLimited": m.rateLimited,
      "internalError": m.internalError, "more": m.more, "goodbye": m.goodbye, "restart": m.restart,
    ]
  }

  @Test("spoken messages: all eleven catalogs, every message")
  func messages() throws {
    let all = try #require(Self.golden["messages"] as? [String: [String: String]])
    #expect(all.count == 11)
    for l in ReplyLang.allCases {
      var want = try #require(all[l.rawValue], "\(l)")
      let chai = want.removeValue(forKey: "busy:Chai")
      #expect(Self.messageDict(Messages.of(l), bot: "拆解师") == want, "\(l)")
      #expect(Messages.of(l).busy("Chai") == chai)
    }
    #expect(Messages.of(code: "nl").badToken == Messages.of(.en).badToken)
  }

  @Test("envelope STYLE: every language, strict, test, custom, disabled, conversation turn")
  func envelopes() throws {
    let all = try #require(Self.golden["envelopes"] as? [String: String])
    for l in ReplyLang.allCases {
      #expect(Envelope.build(id: "abc123abc123", text: "今天天气？", lang: l, strictEcho: true) == all["\(l.rawValue)|strict"])
      #expect(Envelope.build(id: "x", text: "hi", lang: l, strictEcho: false, style: .custom("Be brief."), test: true) == all["\(l.rawValue)|plain|test|custom"])
      #expect(Envelope.build(id: "x", text: "hi", lang: l, strictEcho: true, style: .none) == all["\(l.rawValue)|nostyle"])
      #expect(Envelope.build(id: "abc", text: "and after", lang: l, strictEcho: true, turn: 3) == all["\(l.rawValue)|turn3"])
    }
  }

  @Test("END_WORDS, PROBE_TEXT (with Russian plurals) and maxSpokenChars")
  func catalogs() throws {
    let ends = try #require(Self.golden["endWords"] as? [String: [String]])
    for l in ReplyLang.allCases { #expect(Conversation.endWords[l] == ends[l.rawValue], "\(l)") }
    let probe = try #require(Self.golden["probe"] as? [String: Any])
    let ns = try #require(probe["ns"] as? [Int])
    let text = try #require(probe["text"] as? [String: [String]])
    for l in ReplyLang.allCases { #expect(ns.map { Catalogs.probeText(l, $0) } == text[l.rawValue], "\(l)") }
    #expect(Catalogs.probeSteps == [5, 10, 15, 20, 25, 30, 40, 50, 58])
    #expect(Settings.defaultMaxSpokenChars == (Self.golden["maxSpokenChars"] as? [String: Int]))
  }

  static func problemCodes(_ p: [PhraseProblem]) -> [[String: Any]] {
    p.map { ["code": $0.code.rawValue, "message": $0.message, "blocking": $0.blocking] }
  }

  static func same(_ a: [PhraseProblem], _ b: Any?) -> Bool {
    guard let b = b as? [[String: Any]], a.count == b.count else { return false }
    return zip(a, b).allSatisfy { x, y in x.code.rawValue == y["code"] as? String && x.message == y["message"] as? String && x.blocking == y["blocking"] as? Bool }
  }

  @Test("phrase rows and setup steps: every Siri language, bot, iPhone language and test phrase")
  func profiles() throws {
    let all = try #require(Self.golden["profiles"] as? [[String: Any]])
    #expect(all.count > 500)
    for row in all {
      let siri = try #require(row["siriLang"] as? String)
      let bot = try #require(row["botName"] as? String)
      let ctx = "\(siri) \(bot) \(row["given"] ?? row["keep"] ?? row["phoneLang"] ?? "taken")"
      let p: ShortcutProfile
      if let given = row["given"] as? String {
        p = try Profile.make(botName: bot, siriLang: siri, name: given.trimmingCharacters(in: .whitespaces).isEmpty ? "x" : given)
      } else if row["taken"] != nil {
        p = try Profile.make(botName: bot, siriLang: siri, taken: ["家庭助手", "Grok Bot", "My Grok Bot", "mayordomo"])
      } else if let keep = row["keep"] as? String {
        p = try Profile.make(botName: bot, siriLang: siri, keep: keep)
      } else {
        p = try Profile.make(botName: bot, siriLang: siri, phoneLang: try #require(row["phoneLang"] as? String))
        #expect(p.prompt == row["prompt"] as? String, "\(ctx)")
        #expect(p.speakLang == row["speakLang"] as? String, "\(ctx)")
        #expect(p.replyLang.rawValue == row["replyLang"] as? String, "\(ctx)")
        #expect(p.probeName == row["probeName"] as? String, "\(ctx)")
        #expect(p.labName == row["labName"] as? String, "\(ctx)")
        #expect(p.steps(host: "mac.local") == row["steps"] as? [String], "\(ctx)")
        #expect(p.steps(host: "mac.local", name: "Test Phrase") == row["stepsNamed"] as? [String], "\(ctx)")
      }
      #expect(p.name == row["name"] as? String, "\(ctx)")
      #expect(p.alternatives == row["alternatives"] as? [String], "\(ctx)")
      #expect(Self.same(p.problems, row["problems"]), "\(ctx): \(p.problems.map(\.code))")
    }
  }

  @Test("speech: sanitize, truncate and speakable match on tricky input")
  func speech() throws {
    let all = try #require(Self.golden["speech"] as? [[String: String]])
    for c in all {
      let input = try #require(c["input"])
      #expect(Speech.sanitize(input) == c["sanitized"], "\(input)")
      #expect(Speech.truncate(Speech.sanitize(input), 6) == c["t6"], "\(input)")
      #expect(Speech.speakable(input, 10) == c["t10"], "\(input)")
      #expect(Speech.speakable(input, 16) == c["t16"], "\(input)")
      #expect(Speech.truncate(input, 3) == c["t3"], "\(input)")
    }
  }

  @Test("labels, file names, language table, taken phrases")
  func naming() throws {
    for c in try #require(Self.golden["labels"] as? [[String: String]]) { #expect(labelKey(c["input"]!) == c["key"], "\(c["input"]!)") }
    for c in try #require(Self.golden["fileNames"] as? [[String: String]]) { #expect(ShortcutMaker.safeFileName(c["input"]!) == c["safe"], "\(c["input"]!)") }
    let lang = try #require(Self.golden["lang"] as? [String: Any])
    let options = try #require(lang["siriOptions"] as? [[String: String]])
    #expect(Langs.siriOptions.map { [$0.code, $0.label] } == options.map { [$0["code"]!, $0["label"]!] })
    for (k, v) in try #require(lang["langOfSiri"] as? [String: String]) { #expect(Langs.langOfSiri(k).rawValue == v, "\(k)") }
    for (k, v) in try #require(lang["replyLang"] as? [String: String]) { #expect(Langs.replyLang(k).rawValue == v, "\(k)") }
    for (k, v) in try #require(lang["hey"] as? [String: String]) { #expect(Langs.heySiri(k, "NAME") == v, "\(k)") }
    let t = Profile.takenPhrases([("a", "家庭助手", .active), ("b", "我家助手", .pending), ("c", "居家助手", .retired), ("d", "家庭等待测试", .pending), ("e", "Homebot", .active)])
    #expect(t == Self.golden["taken"] as? [String])
  }
}
