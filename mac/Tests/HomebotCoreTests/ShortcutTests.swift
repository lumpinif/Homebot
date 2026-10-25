// Ported from test/text.test.ts and test/shortcut.test.ts: envelope, speech, plist writer,
// phrase profiles, Shortcut builders, plutil, the signer (fake only).
import Foundation
import Testing

@testable import HomebotCore

@Suite("Envelope and speech")
struct TextTests {
  @Test("request ids are 12 hex chars and unique")
  func ids() {
    let a = Envelope.newRequestId()
    #expect(a.wholeMatch(of: /[0-9a-f]{12}/) != nil)
    #expect(a != Envelope.newRequestId())
  }

  @Test("envelope: marker line, question, echo instruction")
  func envelope() {
    let e = Envelope.build(id: "abc123abc123", text: "今天天气？", lang: .zhCN, strictEcho: true)
    let lines = e.components(separatedBy: "\n")
    #expect(lines[0] == "[Homebot voice · hb:abc123abc123 · zh-CN]")
    #expect(lines[1] == "今天天气？")
    #expect(e.contains(Envelope.echoTag("abc123abc123")))
    #expect(e.contains(Envelope.requestMarker("abc123abc123")))
  }

  @Test("envelope: test mode, English, no echo, custom and disabled style")
  func envelopeModes() {
    let e = Envelope.build(id: "x", text: "hi", lang: .en, strictEcho: false, style: .custom("Be brief."), test: true)
    #expect(e.hasPrefix("[Homebot test · hb:x · en]\nhi\n"))
    #expect(!e.contains("[hb:x]"))
    #expect(e.contains("Be brief."))
    let n = Envelope.build(id: "x", text: "hi", lang: .en, strictEcho: false, style: .none)
    #expect(!n.contains("1-3 short"))
  }

  @Test("sanitize strips markdown, code, links, emoji and list markers")
  func sanitize() {
    #expect(Speech.sanitize("# 标题\n- 第一点 **重要**\n1. 第二点 [链接](https://x.y)\n```js\ncode()\n```\n看 `ls` 和 https://a.b/c 😀👍🏽") == "标题 第一点 重要 第二点 链接 看 ls 和")
  }

  @Test("truncate cuts at a sentence boundary and adds an ellipsis")
  func truncate() {
    #expect(Speech.truncate("短句。", 10) == "短句。")
    #expect(Speech.truncate("第一句话很长。第二句话也很长。第三句", 16) == "第一句话很长。第二句话也很长。…")
    #expect(Speech.truncate("没有标点的一段很长的文字内容", 6) == "没有标点的一…")
  }

  @Test("a zero or negative speech limit never traps (Codex S1 review 12)")
  func badLimit() {
    #expect(Speech.truncate("hello world", -1) == "h…")
    #expect(Speech.truncate("hello world", 0) == "h…")
  }

  @Test("truncate counts code points, not UTF-16 units")
  func codePoints() {
    #expect(Speech.truncate("𠀀𠀀𠀀", 3) == "𠀀𠀀𠀀")
  }

  @Test("speakable combines both; an early boundary is not used")
  func speakable() {
    #expect(Speech.speakable("**Hi.** There is more text here.", 10) == "Hi. There…")
    #expect(Speech.speakable("**Hello there.** More text here.", 16) == "Hello there.…")
  }
}

/// The Shortcut's dictionary-field items as [key: value plist].
func dictOf(_ v: PlistValue?) -> [String: PlistValue] {
  var out: [String: PlistValue] = [:]
  for item in v?["Value"]?["WFDictionaryFieldValueItems"]?.arrayValue ?? [] {
    if let k = item["WFKey"]?["Value"]?["string"]?.stringValue, let val = item["WFValue"] { out[k] = val }
  }
  return out
}

func outputUUID(_ v: PlistValue?) -> String? { v?["Value"]?["attachmentsByRange"]?["{0, 1}"]?["OutputUUID"]?.stringValue }

@Suite("Shortcut files")
struct ShortcutTests {
  @Test("plist: types, escaping, empty containers, refuses what it can't encode")
  func plist() throws {
    let xml = try Plist.xml(.dict([("s", .string("a<b>&c")), ("n", .integer(5)), ("t", .bool(true)), ("f", .bool(false)), ("a", .array([])), ("d", .dict([])), ("nested", .array([.dict([("k", .string("v"))])]))]))
    #expect(xml.contains("<key>s</key>\n\t<string>a&lt;b&gt;&amp;c</string>"))
    #expect(xml.contains("<integer>5</integer>"))
    #expect(xml.contains("<true/>"))
    #expect(xml.contains("<false/>"))
    #expect(xml.contains("<array/>"))
    #expect(xml.contains("<dict/>"))
    #expect(throws: PlistError.self) { try Plist.xml(.dict([("x", .integer(9_007_199_254_740_992))])) }
    #expect(throws: PlistError.self) { try Plist.xml(.dict([("x", .string("bad\u{1}"))])) }
  }

  @Test("profile: English is the default; Siri language drives name, prompt, voice")
  func english() throws {
    let en = try Profile.make(botName: "Chai")
    #expect(en.siriLang == "en-US")
    #expect(en.name == "Grok Bot", "a product phrase first (DESIGN §16, Q16-1)")
    #expect(en.alternatives == ["My Grok Bot", "Our Grok Bot", "Chai"])
    #expect(en.prompt == "What would you like to ask Grok Bot?", "the phrase, never the bot (S25)")
    #expect(en.speakLang == "en-US")
    #expect(en.replyLang == .en)
    #expect(en.problems.isEmpty)
    #expect(try Profile.make(botName: "Chai", siriLang: "en-GB").speakLang == "en-GB")
  }

  @Test("profile: Felix's setup — iPhone English, Siri Chinese")
  func felix() throws {
    let p = try Profile.make(botName: "homebot", siriLang: "zh-CN", phoneLang: "en")
    #expect(p.name == "Grok Bot", "the default in every language; Felix's Chinese Siri ran it (DECISIONS item 33)")
    #expect(p.prompt == "想问Grok Bot什么？", "the phrase the user says, not the bot \"homebot\" (S25)")
    #expect(p.speakLang == "zh-CN")
    #expect(p.replyLang == .zhCN)
    #expect(p.alternatives == ["我的 Grok Bot", "家庭助手", "我家助手"], "native names are suggestions; the bot \"homebot\" is not")
    #expect(p.problems.isEmpty)
    #expect(p.steps(host: "mac.local").joined(separator: "\n").contains("Allow Running When Locked"))
    let zh = try Profile.make(botName: "homebot", siriLang: "zh-CN", phoneLang: "zh-Hans")
    #expect(zh.steps(host: "mac.local").joined(separator: "\n").contains("锁定时允许运行"))
    #expect(zh.steps(host: "mac.local", name: "家庭等待测试").joined(separator: "\n").contains("轻点“家庭等待测试”"))
  }

  func codes(_ name: String, _ siriLang: String = "zh-CN", taken: [String] = []) throws -> [String] {
    try Profile.make(botName: "homebot", siriLang: siriLang, name: name, taken: taken).problems.map { $0.blocking ? $0.code.rawValue : "\($0.code.rawValue)?" }
  }

  @Test("profile: script, digits and first words are advice; unsafe names and phrases in use block (DESIGN §16.2)")
  func phraseRules() throws {
    let han = try Profile.make(botName: "拆解师", siriLang: "zh-CN")
    #expect(han.name == "Grok Bot")
    #expect(han.prompt == "想问Grok Bot什么？", "the phrase, not the bot")
    #expect(try Profile.make(botName: "拆解师", siriLang: "zh-CN", name: "homebot 你好").prompt == "想问什么？", "a phrase with advice is left out of the question")
    #expect(han.alternatives == ["我的 Grok Bot", "家庭助手", "我家助手", "拆解师"])
    #expect(try codes("家庭助手") == [])
    #expect(try codes("homebot 你好") == ["wrong-script?"])
    #expect(try codes("家庭助手2") == ["wrong-script?"], "digits are advice")
    #expect(try codes("家庭助手！") == ["wrong-script?"], "symbols are advice")
    #expect(try codes("问拆解师") == ["search-start?"], "strong advice: a device failure (DECISIONS item 12)")
    #expect(try codes("问问homebot") == ["wrong-script?", "search-start?"])
    #expect(try codes("Grok Bot") == [], "the brand is fine in every language (DECISIONS item 33)")
    for l in Langs.siriOptions.map(\.code) {
      #expect(try codes("Grok Bot", l) == [], "\(l)")
      #expect(try codes("grok bot", l) == [], "\(l): any case")
    }
    #expect(try codes("我的 Grok Bot") == [])
    #expect(try codes("Grok Bot助手") == [], "a native word next to the brand is fine")
    #expect(try codes("うちの Grok Bot", "ja-JP") == [])
    #expect(try codes("мой Grok Bot", "ru-RU") == [])
    #expect(try codes("问 Grok Bot") == ["search-start?"], "a leading 问 is still a device failure (DECISIONS item 12)")
    #expect(try codes("Grok Bot 2", "en-US") == ["wrong-script?"], "digits are still advice")
    #expect(try codes("Grok Bot homebot") == ["wrong-script?"], "other Latin words still are, in Chinese")
    #expect(try codes("a/b", "en-US") == ["wrong-script?", "unsafe-chars"], "a name iOS would change blocks")
    #expect(try codes(".hidden", "en-US") == ["wrong-script?", "unsafe-chars"])
    #expect(try codes("问问Grok Bot", taken: ["问问grok bot"]) == ["search-start?", "in-use"], "uniqueness stays hard")
    #expect(try codes("Grok\u{FEFF}Bot", "en-US", taken: ["Grok Bot"]).contains("in-use"), "JavaScript's spaces, U+FEFF included (Codex review)")
    #expect(labelKey(" Grok\u{3000}\u{A0}Bot\u{FEFF}") == "grok bot")
    #expect(try codes("Homebot", "en-US") == [])
    #expect(try codes("Kitchen Bot", "en-US") == [])
    #expect(try codes("Ask Chai", "en-US") == ["bad-start?"], "advice only: no device evidence yet")
    #expect(try codes("打开助手") == ["bad-start?"])
    #expect(try codes("Asking Chai", "en-US") == [], "only whole first words count in English")
    #expect(try codes("家庭助手 bot", "en-US") == ["wrong-script?"])
    #expect(try codes("Home Bot 2", "en-US") == ["wrong-script?"])
    #expect(try codes("house butler", "en-US", taken: ["House  Butler"]) == ["in-use"])
    #expect(try codes("家庭助手", taken: ["家庭助手".decomposedStringWithCanonicalMapping]) == ["in-use"])
    let taken = try Profile.make(botName: "homebot", siriLang: "zh-CN", taken: ["Grok Bot"])
    #expect(taken.name == "我的 Grok Bot", "the default skips phrases in use, in any language")
    #expect(taken.alternatives == ["家庭助手", "我家助手"])
    #expect(try Profile.make(botName: "Home Bot", siriLang: "en-US").alternatives == ["My Grok Bot", "Our Grok Bot"], "a bot named like the app is never suggested")
    #expect(try Profile.make(botName: "Chai", siriLang: "en-US").alternatives == ["My Grok Bot", "Our Grok Bot", "Chai"])
  }

  @Test("takenPhrases: every usable Homebot Shortcut on the phone, minus the one replaced")
  func takenPhrases() {
    let list: [(id: String, label: String, state: TokenState)] = [("a", "家庭助手", .active), ("b", "我家助手", .pending), ("c", "居家助手", .retired), ("d", "家庭等待测试", .pending), ("e", "Homebot", .active)]
    #expect(Profile.takenPhrases(list) == ["家庭助手", "我家助手", "家庭等待测试", "Homebot"])
    #expect(Profile.takenPhrases(list, replaces: "a") == ["我家助手", "家庭等待测试", "Homebot"])
  }

  @Test("every Siri language: same options as the iPhone menu, a valid default phrase, a prompt, its own envelope")
  func everyLanguage() throws {
    #expect(Langs.siriOptions.map(\.label) == Lang.allCases.map(\.info.name))
    for (code, _) in Langs.siriOptions {
      let p = try Profile.make(botName: "Chai", siriLang: code)
      #expect(p.problems.isEmpty, "\(code): \(p.name)")
      #expect(!p.alternatives.isEmpty)
      #expect(p.speakLang == code)
      #expect(p.prompt.contains(p.name) && !p.prompt.contains("Chai"), "\(code): the prompt names the phrase, never the bot (S25)")
      #expect(p.name == "Grok Bot", "\(code): the default in every language (DECISIONS item 33)")
      #expect(p.alternatives.contains { $0 != "Grok Bot" && $0.contains("Grok Bot") }, "\(code): a \"my Grok Bot\" form")
      #expect(code.hasPrefix("en") || p.alternatives.contains { !$0.contains("Grok") }, "\(code): a native name")
      #expect(Langs.heySiri(code, p.name).contains(p.name))
      #expect(Envelope.build(id: "abc", text: "q", lang: Langs.replyLang(code), strictEcho: true).contains("[hb:abc]"))
      #expect((Conversation.endWords[Langs.replyLang(code)] ?? []).count >= 4)
    }
    #expect(Langs.langOfSiri("en-GB") == .en)
    #expect(try Profile.make(botName: "Chai", siriLang: "en-GB").speakLang == "en-GB")
  }

  @Test("profile: custom name, validation")
  func validation() async throws {
    #expect(try Profile.make(botName: "Chai", name: "  Chai Voice ").name == "Chai Voice")
    let siri = await errorText { _ = try Profile.make(botName: "x", siriLang: "nl-NL") }
    #expect(siri?.contains("Siri language") == true)
    let phone = await errorText { _ = try Profile.make(botName: "x", phoneLang: "xx") }
    #expect(phone?.contains("iPhone language") == true)
    let blank = await errorText { _ = try Profile.make(botName: "x", name: "  ") }
    #expect(blank?.contains("1-60") == true)
  }

  @Test("profile: every iPhone language has the five steps, naming the Shortcut and the gateway")
  func steps() throws {
    for l in Lang.allCases {
      let steps = try Profile.make(botName: "homebot", phoneLang: l.rawValue).steps(host: "mac.local", name: "Test Phrase")
      #expect(steps.count == 5, "\(l)")
      #expect(steps[1].contains("Test Phrase") && steps[1].contains("mac.local"), "\(l)")
      #expect(steps[4].contains("Test Phrase"), "\(l)")
      #expect(!steps.joined().contains("${") && !steps.joined().contains("\u{E000}"), "\(l)")
    }
  }

  @Test("replacement: the old phrase is kept unless a blocking rule refuses it (re-review S2)")
  func keep() throws {
    let advice = try Profile.make(botName: "homebot", siriLang: "en-US", keep: "Call Butler")
    #expect(advice.name == "Call Butler")
    #expect(advice.problems.allSatisfy { !$0.blocking })
    #expect(try Profile.make(botName: "homebot", siriLang: "zh-CN", keep: "homebot 你好").name == "homebot 你好", "the script rule is advice")
    #expect(try Profile.make(botName: "homebot", siriLang: "zh-CN", keep: "a/b").name == "Grok Bot", "a name iOS would change is not kept")
    let old = TokenInfo(id: "a", bots: [], label: "家庭助手", state: .active, createdAt: 0, siriLang: "zh-CN")
    #expect(Profile.keptPhrase(old, siriLang: "zh-CN") == "家庭助手")
    #expect(Profile.keptPhrase(old, siriLang: "en-US") == "家庭助手", "a language change never renames a Shortcut (DECISIONS item 33)")
    #expect(Profile.keptPhrase(TokenInfo(id: "b", bots: [], label: "Grok Bot", state: .active, createdAt: 0), siriLang: "en-GB") == "Grok Bot", "English variants share a phrase table")
  }

  @Test("ask Shortcut: three actions wired by UUID, token header, JSON body, speech language")
  func ask() async throws {
    let w = try ShortcutBuilder().askShortcut(baseUrl: "http://mac.local:8787/ignored/path", botKey: "chai", token: "TOKEN", prompt: "Q?", speakLang: "zh-CN")
    let actions = try #require(w["WFWorkflowActions"]?.arrayValue)
    #expect(actions.map { $0["WFWorkflowActionIdentifier"]?.stringValue } == ["is.workflow.actions.ask", "is.workflow.actions.downloadurl", "is.workflow.actions.speaktext"])
    let ask = actions[0]["WFWorkflowActionParameters"], dl = actions[1]["WFWorkflowActionParameters"], speak = actions[2]["WFWorkflowActionParameters"]
    #expect(dl?["WFURL"]?.stringValue == "http://mac.local:8787/v1/ask")
    #expect(dl?["WFHTTPMethod"]?.stringValue == "POST")
    #expect(dl?["WFHTTPBodyType"]?.stringValue == "JSON")
    #expect(dictOf(dl?["WFHTTPHeaders"])["X-Homebot-Token"]?["Value"]?["string"]?.stringValue == "TOKEN")
    let body = dictOf(dl?["WFJSONValues"])
    #expect(body["bot"]?["Value"]?["string"]?.stringValue == "chai")
    #expect(outputUUID(body["text"]) == ask?["UUID"]?.stringValue)
    #expect(outputUUID(speak?["WFText"]) == dl?["UUID"]?.stringValue)
    #expect(speak?["WFSpeakTextLanguage"]?.stringValue == "zh-CN")
    #expect(speak?["WFSpeakTextWait"] == .bool(true))
    #expect(ask?["WFInputType"]?.stringValue == "Text")
    await #expect(throws: ShortcutBuilder.BuildError.self) { _ = try ShortcutBuilder().askShortcut(baseUrl: "file:///x", botKey: "b", token: "t", prompt: "q", speakLang: "en-US") }
  }

  @Test("probe Shortcut: GET /v1/probe-wait with token, then speak")
  func probe() throws {
    let w = try ShortcutBuilder().probeShortcut(baseUrl: "http://mac.local:8787", token: "T", speakLang: "en-US")
    let actions = try #require(w["WFWorkflowActions"]?.arrayValue)
    #expect(actions[0]["WFWorkflowActionParameters"]?["WFURL"]?.stringValue == "http://mac.local:8787/v1/probe-wait")
    #expect(actions[0]["WFWorkflowActionParameters"]?["WFHTTPMethod"]?.stringValue == "GET")
    #expect(actions[1]["WFWorkflowActionIdentifier"]?.stringValue == "is.workflow.actions.speaktext")
  }

  @Test("generated Shortcut XML passes plutil -lint", arguments: ["ask", "probe", "lab", "conversation", "entry"])
  func plutil(kind: String) throws {
    let p = try Profile.make(botName: "拆解师 & <Co>", siriLang: "zh-CN")
    let b = ShortcutBuilder()
    let w: PlistValue = switch kind {
    case "ask": try b.askShortcut(baseUrl: "http://mac.local:8787", botKey: "chai", token: "t", prompt: p.prompt, speakLang: p.speakLang)
    case "probe": try b.probeShortcut(baseUrl: "http://mac.local:8787", token: "t", speakLang: p.speakLang)
    case "lab": try b.labShortcut(baseUrl: "http://mac.local:8787", token: "t", speakLang: p.speakLang)
    case "entry": try b.entryShortcut(baseUrl: "http://mac.local:8787", token: "t", speakLang: p.speakLang)
    default: try b.conversationShortcut(baseUrl: "http://mac.local:8787", botKey: "chai", token: "t", prompt: p.prompt, speakLang: p.speakLang)
    }
    #expect(try plutilLint(try Plist.xml(w)))
  }

  @Test("signer: retries with backoff and alternates modes; argument array only")
  func signerRetries() async throws {
    let calls = LockedBox<[[String]]>([])
    let waits = LockedBox<[Int]>([])
    let r = try await Signer.sign(input: "/tmp/in", output: "/tmp/out", run: { cmd, args in
      let n = calls.mutate { $0.append([cmd] + args); return $0.count }
      if n < 3 { throw CommandFailed(status: 1) }
    }, wait: { ms in waits.mutate { $0.append(ms) } })
    #expect(r.mode == .peopleWhoKnowMe && r.attempts == 3)
    #expect(calls.value.map { $0[6] } == ["people-who-know-me", "anyone", "people-who-know-me"])
    #expect(calls.value[0] == ["/bin/sh"] + Signer.umaskLauncher + ["/usr/bin/shortcuts", "sign", "--mode", "people-who-know-me", "--input", "/tmp/in", "--output", "/tmp/out"])
    #expect(waits.value == [2000, 4000])
  }

  @Test("S5: the signer's output is 0600 from creation, also when signing fails midway (fake signer)")
  func signerUmask() async throws {
    let dir = try tmpDir()
    // Fake `shortcuts`: creates the output with default permissions, then succeeds or fails.
    // argv: sign --mode <m> --input <in> --output <out>  ($7 = out)
    let fake = dir.appendingPathComponent("fake-shortcuts")
    try "#!/bin/sh\nprintf signed > \"$7\"\n[ \"$3\" = \"anyone\" ] && exit 0\nexit 1\n".write(to: fake, atomically: true, encoding: .utf8)
    chmod(fake.path, 0o700)
    let prev = umask(0o022) // a normal, permissive parent umask
    defer { umask(prev) }
    let failed = dir.appendingPathComponent("failed out.shortcut")
    let e = await errorText { _ = try await Signer.sign(input: "in", output: failed.path, attempts: 1, command: fake.path, wait: { _ in }) }
    #expect(e?.contains("signing failed") == true)
    #expect(modeOf(failed) == 0o600, "partial output left by a failing signer is private")
    let ok = dir.appendingPathComponent("it's \"ok\"; $(x).shortcut") // a hostile path stays one argument
    let r = try await Signer.sign(input: "in", output: ok.path, attempts: 2, command: fake.path, wait: { _ in })
    #expect(r.mode == .anyone)
    #expect(modeOf(ok) == 0o600)
  }

  @Test("signer: gives up with a clear error")
  func signerGivesUp() async {
    let e = await errorText { _ = try await Signer.sign(input: "a", output: "b", attempts: 2, run: { _, _ in throw CommandFailed(status: 1) }, wait: { _ in }) }
    #expect(e?.contains("signing failed after 2 attempts (last exit: 1)") == true)
  }
}

/// A value shared with @Sendable closures in tests.
final class LockedBox<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var v: T
  init(_ v: T) { self.v = v }
  var value: T { lock.withLock { v } }
  @discardableResult
  func mutate<R>(_ f: (inout T) -> R) -> R { lock.withLock { f(&v) } }
}
