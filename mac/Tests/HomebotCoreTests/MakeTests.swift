// Ported from test/shortcut-cli.test.ts (the build itself; CLI output, settings and the HTTP
// round trip move to S2/S3), test/lab.test.ts (runs, lab Shortcut) and test/setup.test.ts
// (add by exact name).
import Foundation
import Testing

@testable import HomebotCore

let chai = Bot(key: "chai", name: "homebot", sessionId: "14752726", strictEcho: true)

struct MakeEnv {
  let stores: Stores
  var tokens: TokenStore { stores.tokens }
  var shortcutsDir: URL { stores.dir.appendingPathComponent("Shortcuts") }

  static func make() async throws -> MakeEnv {
    let s = try await Stores.fresh()
    try await s.lifecycle.add(chai, cursor: "1", maxSeq: "1")
    return MakeEnv(stores: s)
  }

  func build(_ profile: ShortcutProfile, kind: ShortcutKind = .ask, baseUrl: String = "http://felix-mac.local:8787", replaces: String? = nil, sign: SignFn? = nil) async throws -> MadeShortcut {
    try await ShortcutMaker.make(tokens: tokens, lifecycle: stores.lifecycle, bots: [chai], profile: profile, baseUrl: baseUrl, kind: kind, replaces: replaces, sign: sign)
  }
}

/// The token a built Shortcut carries.
func tokenIn(_ xml: String) -> String? {
  xml.firstMatch(of: /<string>X-Homebot-Token<\/string>[\s\S]*?<key>WFValue<\/key>\s*<dict>\s*<key>Value<\/key>\s*<dict>\s*<key>string<\/key>\s*<string>([^<]+)<\/string>/).map { String($0.1) }
}

@Suite("Building a Shortcut")
struct MakeTests {
  @Test("default build: English, private file named after the Shortcut, pending token")
  func defaultBuild() async throws {
    let e = try await MakeEnv.make()
    let m = try await e.build(try Profile.make(botName: chai.name))
    #expect(m.name == "Grok Bot")
    #expect(m.file.lastPathComponent == "Grok Bot.unsigned.shortcut")
    #expect(m.file.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == e.shortcutsDir.standardizedFileURL)
    #expect(!m.signed)
    #expect(modeOf(m.file) == 0o600)
    #expect(modeOf(m.file.deletingLastPathComponent()) == 0o700)
    let xml = try String(contentsOf: m.file, encoding: .utf8)
    #expect(xml.contains("<string>http://felix-mac.local:8787/v1/ask</string>"))
    #expect(xml.contains("<string>en-US</string>"))
    #expect(xml.contains("What would you like to ask Grok Bot?"), "the phrase, never the bot (S25)")
    let info = try #require(await e.tokens.list().first)
    #expect(info.state == .pending && info.label == "Grok Bot" && info.siriLang == "en-US" && info.mode == .single)
    #expect(info.bots == [BotGrant(key: "chai", sessionId: chai.sessionId)])
    #expect(try await e.tokens.verify(try #require(tokenIn(xml)), bot: "chai").isOK, "the file's token is the issued one")
    #expect(try plutilLint(xml))
  }

  @Test("Felix's setup: iPhone English, Siri Chinese")
  func felix() async throws {
    let e = try await MakeEnv.make()
    let m = try await e.build(try Profile.make(botName: chai.name, siriLang: "zh-CN", phoneLang: "en"), baseUrl: "http://192.168.1.5:8787")
    #expect(m.name == "Grok Bot")
    let xml = try String(contentsOf: m.file, encoding: .utf8)
    #expect(xml.contains("<key>WFSpeakTextLanguage</key>\n\t\t\t\t<string>zh-CN</string>") || xml.contains("zh-CN"))
    #expect(xml.contains("想问 Grok Bot 什么？"))
    #expect(xml.contains("http://192.168.1.5:8787/v1/ask"))
  }

  @Test("the artifact is deleted when its token is first used")
  func deletedOnUse() async throws {
    let e = try await MakeEnv.make()
    let m = try await e.build(try Profile.make(botName: chai.name))
    let token = try #require(tokenIn(try String(contentsOf: m.file, encoding: .utf8)))
    #expect(try await e.stores.lifecycle.admit(token, bot: "chai").isOK)
    #expect(try FileManager.default.contentsOfDirectory(atPath: e.shortcutsDir.path) == [])
  }

  @Test("signing with a fake signer: the signed file keeps the name, the unsigned one is removed")
  func fakeSign() async throws {
    let e = try await MakeEnv.make()
    let m = try await e.build(try Profile.make(botName: chai.name), sign: { input, output in
      try FileManager.default.copyItem(atPath: input, toPath: output)
    })
    #expect(m.signed)
    #expect(m.file.lastPathComponent == "Grok Bot.shortcut")
    #expect(modeOf(m.file) == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: m.file.deletingLastPathComponent().path) == ["Grok Bot.shortcut"])
  }

  @Test("signing failure: error, token revoked, files removed")
  func signFailure() async throws {
    let e = try await MakeEnv.make()
    let err = await errorText {
      _ = try await e.build(try Profile.make(botName: chai.name), sign: { _, _ in throw SignError(description: "signing failed after 5 attempts (last exit: 1)") })
    }
    #expect(err?.contains("signing failed") == true)
    #expect(await e.tokens.list().map(\.state) == [.retired])
    #expect(try FileManager.default.contentsOfDirectory(atPath: e.shortcutsDir.path) == [])
  }

  @Test("names iOS would change are refused before a token exists (DESIGN §16.2)", arguments: ["../../evil:/name", ".hidden", "back\\slash"])
  func hostileNames(name: String) async throws {
    let e = try await MakeEnv.make()
    let err = await errorText { _ = try await e.build(try Profile.make(botName: chai.name, name: name)) }
    #expect(err?.contains("iOS would change") == true, "\(err ?? "")")
    #expect(await e.tokens.list().isEmpty, "no token issued")
    #expect(!FileManager.default.fileExists(atPath: e.stores.dir.appendingPathComponent("evil").path))
  }

  @Test("script and leading words are advice: a mixed or 问 phrase is built under its own name (DECISIONS item 29)")
  func leadingWords() async throws {
    let e = try await MakeEnv.make()
    for name in ["问拆解师", "homebot 你好", "问问Grok Bot"] {
      let p = try Profile.make(botName: chai.name, siriLang: "zh-CN", name: name)
      #expect(!p.problems.isEmpty && !p.problems.contains(where: \.blocking), "\(name)")
      #expect(try await e.build(p).name == name)
    }
    #expect(try Profile.make(botName: chai.name, siriLang: "zh-CN", name: "问拆解师").problems.contains { $0.code == .searchStart && $0.message.contains("web search") })
    let advice = try Profile.make(botName: chai.name, name: "Ask Chai")
    #expect(advice.problems.contains { !$0.blocking && $0.message.contains("may be taken by Siri") })
    _ = try await e.build(advice)
  }

  @Test("a phrase already used by another Shortcut is refused; a replacement may keep its phrase")
  func phraseInUse() async throws {
    let e = try await MakeEnv.make()
    let first = try await e.build(try Profile.make(botName: chai.name))
    #expect(first.name == "Grok Bot")
    let taken = await Profile.takenPhrases(e.tokens.list().map { ($0.id, $0.label, $0.state) })
    let second = try await e.build(try Profile.make(botName: chai.name, taken: taken))
    #expect(second.name == "My Grok Bot", "the next unused default")
    let dup = await errorText { _ = try await e.build(try Profile.make(botName: chai.name, name: "grok bot")) }
    #expect(dup?.contains("already uses") == true, "\(dup ?? "nil")")
    _ = try await e.build(try Profile.make(botName: chai.name, name: "Grok Bot"), replaces: first.tokenId)
  }

  @Test("a token revoked while its file was being signed leaves no file and fails (Codex S1 review 9)")
  func revokedDuringSign() async throws {
    let e = try await MakeEnv.make()
    let tokens = e.tokens
    let err = await errorText {
      _ = try await e.build(try Profile.make(botName: chai.name), sign: { input, output in
        let id = URL(fileURLWithPath: input).deletingLastPathComponent().lastPathComponent
        try FileManager.default.copyItem(atPath: input, toPath: output)
        _ = try await tokens.revoke(id) // another process revokes while the signer runs
      })
    }
    #expect(err?.contains("revoked while it was being built") == true, "\(err ?? "nil")")
    #expect(try FileManager.default.contentsOfDirectory(atPath: e.shortcutsDir.path) == [])
  }

  @Test("M2 S3: the probe build is named after the probe Shortcut, never the Ask Shortcut")
  func probeName() async throws {
    let e = try await MakeEnv.make()
    let p = try Profile.make(botName: chai.name, siriLang: "zh-CN", phoneLang: "zh-Hans")
    let m = try await e.build(p, kind: .probe)
    #expect(m.name == "家庭等待测试")
    let steps = p.steps(host: "mac.local", name: m.name).joined(separator: "\n")
    #expect(steps.contains("轻点“家庭等待测试”运行一次"))
    #expect(steps.contains("“嘿 Siri，家庭等待测试”"))
    #expect(!steps.contains("家庭助手"))
    #expect(await e.tokens.list().first?.kind == .probe)
    #expect(try String(contentsOf: m.file, encoding: .utf8).contains("/v1/probe-wait"))
  }

  @Test("M2 N1: invalid input fails before a token exists; a later failure revokes and leaves the old one alone")
  func failures() async throws {
    let e = try await MakeEnv.make()
    let bad = await errorText { _ = try await e.build(try Profile.make(botName: chai.name), baseUrl: "file:///invalid") }
    #expect(bad?.contains("gateway URL must be http") == true)
    #expect(await e.tokens.list().isEmpty, "no token issued")
    let ok = try await e.build(try Profile.make(botName: chai.name))
    let oldToken = try #require(tokenIn(try String(contentsOf: ok.file, encoding: .utf8)))
    let failed = await errorText {
      _ = try await e.build(try Profile.make(botName: chai.name, name: "Chai Voice"), replaces: ok.tokenId, sign: { _, _ in throw SignError(description: "signing failed") })
    }
    #expect(failed?.contains("signing failed") == true)
    let list = await e.tokens.list()
    #expect(list.count == 2)
    #expect(list.first { $0.id == ok.tokenId }?.state == .pending, "the old token is untouched")
    #expect(list.first { $0.id != ok.tokenId }?.state == .retired, "the failed build's token is not usable")
    #expect(try FileManager.default.contentsOfDirectory(atPath: e.shortcutsDir.path) == [ok.tokenId])
    #expect(try await e.stores.lifecycle.admit(oldToken, bot: "chai").isOK, "the old Shortcut still works")
  }

  @Test("M2 S4: replacing another bot's token is refused and issues nothing")
  func replacesOtherBot() async throws {
    let e = try await MakeEnv.make()
    let other = Bot(key: "other", name: "Other", sessionId: "999", strictEcho: true)
    try await e.stores.lifecycle.add(other, cursor: "1", maxSeq: "1")
    let a = try await ShortcutMaker.make(tokens: e.tokens, lifecycle: e.stores.lifecycle, bots: [other], profile: try Profile.make(botName: "Other"), baseUrl: "http://mac.local:8787")
    let err = await errorText { _ = try await e.build(try Profile.make(botName: chai.name, name: "Chai Voice"), replaces: a.tokenId) }
    #expect(err?.contains("answers for bot \"other\"") == true)
    #expect(await e.tokens.list().count == 1)
  }

  @Test("conversation and lab builds: the loop posts to /v1/ask, the lab to /v1/lab")
  func conversationAndLab() async throws {
    let e = try await MakeEnv.make()
    let conv = try await e.build(try Profile.make(botName: chai.name, siriLang: "zh-CN", name: "我家助手"), kind: .conversation)
    let xml = try String(contentsOf: conv.file, encoding: .utf8)
    #expect(xml.contains("/v1/ask</string>"))
    #expect(xml.contains("is.workflow.actions.repeat.count"))
    #expect(await e.tokens.list().first { $0.id == conv.tokenId }?.mode == .conversation)
    let lab = try await e.build(try Profile.make(botName: chai.name, siriLang: "zh-CN"), kind: .lab)
    #expect(lab.name == "家庭实验")
    #expect(try String(contentsOf: lab.file, encoding: .utf8).contains("/v1/lab</string>"))
    #expect(await e.tokens.list().first { $0.id == lab.tokenId }?.kind == .lab)
  }

  @Test("file names are made safe as one path segment")
  func safeNames() {
    #expect(ShortcutMaker.safeFileName("a/b\\c:d") == "a_b_c_d")
    #expect(ShortcutMaker.safeFileName("..hidden") == "_hidden")
    #expect(ShortcutMaker.safeFileName("") == "Homebot")
  }
}

@Suite("Lab Shortcut and runs (from test/lab.test.ts)")
struct LabShortcutTests {
  func blocks(_ actions: [PlistValue], _ id: String) -> (open: Int, close: Int) {
    let mine = actions.filter { $0["WFWorkflowActionIdentifier"]?.stringValue == id }
    let modes = mine.map { $0["WFWorkflowActionParameters"]?["WFControlFlowMode"] }
    return (modes.filter { $0 == .integer(0) }.count, modes.filter { $0 == .integer(2) }.count)
  }

  @Test("lab Shortcut: balanced loop and conditions, posts to /v1/lab, speaks in the Siri language")
  func lab() throws {
    let w = try ShortcutBuilder().labShortcut(baseUrl: "http://mac.local:8787/x", token: "secret-token", speakLang: "zh-CN")
    let a = try #require(w["WFWorkflowActions"]?.arrayValue)
    #expect(blocks(a, "is.workflow.actions.repeat.count") == (1, 1))
    let ifs = blocks(a, "is.workflow.actions.conditional")
    #expect(ifs.open == ifs.close)
    #expect(ifs.open == 3, "start check, V1/V2 choice, end check")
    let posts = a.filter { $0["WFWorkflowActionIdentifier"]?.stringValue == "is.workflow.actions.downloadurl" }
    #expect(posts.map { $0["WFWorkflowActionParameters"]?["WFURL"]?.stringValue } == ["http://mac.local:8787/v1/lab", "http://mac.local:8787/v1/lab"])
    let speaks = a.filter { $0["WFWorkflowActionIdentifier"]?.stringValue == "is.workflow.actions.speaktext" }
    #expect(speaks.count >= 3 && speaks.allSatisfy { $0["WFWorkflowActionParameters"]?["WFSpeakTextLanguage"]?.stringValue == "zh-CN" })
    let rep = a.first { $0["WFWorkflowActionIdentifier"]?.stringValue == "is.workflow.actions.repeat.count" }
    #expect(rep?["WFWorkflowActionParameters"]?["WFRepeatCount"] == .integer(Int64(ShortcutBuilder.labSteps)))
    // Every variable read is set somewhere.
    let xml = try Plist.xml(w)
    let read = Set(xml.matches(of: /<key>VariableName<\/key>\s*<string>([^<]+)<\/string>/).map { String($0.1) })
    let set = Set(a.filter { $0["WFWorkflowActionIdentifier"]?.stringValue == "is.workflow.actions.setvariable" }.compactMap { $0["WFWorkflowActionParameters"]?["WFVariableName"]?.stringValue })
    for v in read { #expect(set.contains(v) || v == "Repeat Index", "variable \(v) is set before use") }
    #expect(xml.components(separatedBy: "secret-token").count - 1 == 2, "the token is in both requests and nowhere else")
    #expect(try plutilLint(try Plist.xml(try ShortcutBuilder().labShortcut(baseUrl: "http://mac.local:8787", token: "t", speakLang: "en-US"))))
  }

  @Test("runs: ordered steps, repeats share one response, anything else is unknown")
  func orderedSteps() async throws {
    let clock = Clock(0)
    let runs = RunStore<Int, String>(ttlMs: 1000, now: clock.fn)
    let made = LockedBox(0)
    let a = await runs.start(tokenId: "tok", state: 1) { id in made.mutate { $0 += 1 }; return "start:\(id)" }
    #expect(await a.response.value == "start:\(a.id)")
    #expect(await runs.check(a.id, tokenId: "tok", step: 1).kind == "next")
    #expect(await runs.check(a.id, tokenId: "tok", step: 2).kind == "unknown", "a skipped step")
    #expect(await runs.check(a.id, tokenId: "other", step: 1).kind == "unknown", "another token's run")
    #expect(await runs.check("nope", tokenId: "tok", step: 1).kind == "unknown")
    let r1 = try await runs.take(a.id, step: 1, input: "q") { made.mutate { $0 += 1 }; return "one" }
    guard case .repeat(let again, _) = await runs.check(a.id, tokenId: "tok", step: 1, input: "q") else { Issue.record("expected repeat"); return }
    #expect(await again.value == "one")
    #expect(await r1.value == "one")
    #expect(made.value == 2, "a repeated step never runs its work again")
    #expect(await runs.check(a.id, tokenId: "tok", step: 0).kind == "unknown", "an old step")
    let b = await runs.start(tokenId: "tok", state: 2) { _ in "b" }
    #expect(a.id != b.id, "overlapping runs of one Shortcut have their own state")
    clock.now = 999
    #expect(await runs.check(a.id, tokenId: "tok", step: 2).kind == "next", "each step renews the run")
    clock.now = 2100
    #expect(await runs.check(a.id, tokenId: "tok", step: 2).kind == "unknown", "expired")
    #expect(await runs.size == 0)
  }

  @Test("runs: an ended run keeps its last response for retries and takes no later step (review S4)")
  func endedRun() async throws {
    let runs = RunStore<Int, String>()
    let gate0 = LockedBox(false)
    let a = await runs.start(tokenId: "tok", state: 0) { _ in
      while !gate0.value { try? await Task.sleep(nanoseconds: 1_000_000) }
      return "start"
    }
    #expect(await runs.check(a.id, tokenId: "tok", step: 1).kind == "early", "the start response is not ready yet")
    gate0.mutate { $0 = true }
    _ = await a.response.value
    for _ in 0..<1000 where await runs.check(a.id, tokenId: "tok", step: 1).kind != "next" { try await Task.sleep(nanoseconds: 1_000_000) }
    let gate1 = LockedBox(false)
    let slow = try await runs.take(a.id, step: 1) {
      while !gate1.value { try? await Task.sleep(nanoseconds: 1_000_000) }
      return "one"
    }
    #expect(await runs.check(a.id, tokenId: "tok", step: 2).kind == "early", "step 1 is still being made")
    await runs.finish(a.id)
    gate1.mutate { $0 = true }
    #expect(await slow.value == "one")
    guard case .repeat(let again, _) = await runs.check(a.id, tokenId: "tok", step: 1) else { Issue.record("expected repeat"); return }
    #expect(await again.value == "one", "a retry of the final step gets the final response")
    #expect(await runs.check(a.id, tokenId: "tok", step: 2).kind == "ended")
  }

  @Test("runs: a repeat with different input is reported as changed (DESIGN §20.5 rule 4)")
  func changedInput() async throws {
    let runs = RunStore<Int, String>()
    let a = await runs.start(tokenId: "tok", state: 0) { _ in "s" }
    _ = await a.response.value
    for _ in 0..<1000 where await runs.check(a.id, tokenId: "tok", step: 1).kind != "next" { try await Task.sleep(nanoseconds: 1_000_000) }
    _ = try await runs.take(a.id, step: 1, input: "first") { "one" }
    #expect(await runs.check(a.id, tokenId: "tok", step: 1, input: "first").kind == "repeat")
    #expect(await runs.check(a.id, tokenId: "tok", step: 1, input: "second").kind == "changed")
  }
}
