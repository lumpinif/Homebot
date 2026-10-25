// The make flow's opt-in "Keep listening after each answer" (DESIGN §18, Q18-1): it builds the
// same conversation Shortcut as `homebot shortcut build --conversation`, the list shows it as
// plain metadata, and making it again or in a new language keeps the kind.
import Foundation
import Testing

import HomebotCore
import HomebotTestSupport
@testable import HomebotUI

@MainActor
@Suite(.serialized) struct ConversationChoiceTests {
  @Test func offByDefaultAndBuiltLikeTheCommand() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("homebot", sid: "14752726")
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.addBySession("14752726", name: "homebot", strict: true))
    let k = m.snapshot.bots[0].key

    #expect(ShortcutInput(bot: k).conversation == false)
    let plain = try #require(await m.makeShortcut(ShortcutInput(bot: k), sign: false))
    #expect(plain.endWord == nil)
    #expect(m.snapshot.tokens.first { $0.id == plain.tokenId }?.mode == .single)

    let talk = try #require(await m.makeShortcut(ShortcutInput(bot: k, replaces: "", conversation: true), sign: false))
    let t = try #require(m.snapshot.tokens.first { $0.id == talk.tokenId })
    #expect(t.mode == .conversation && t.kind == .ask)
    #expect(talk.endWord == "stop", "the end word in the Shortcut's Siri language")
    // The file is the looping Shortcut: it counts steps, the plain one does not.
    let xml = try String(contentsOf: try m.builtFile(talk.tokenId).file, encoding: .utf8)
    let one = try String(contentsOf: try m.builtFile(plain.tokenId).file, encoding: .utf8)
    #expect(xml.contains("Repeat Index") && !one.contains("Repeat Index"))

    // In Chinese, the end word is Chinese.
    let zh = try #require(await m.makeShortcut(ShortcutInput(bot: k, replaces: "", siriLang: "zh-CN", conversation: true), sign: false))
    #expect(zh.endWord == "结束")
  }

  @Test func theOnePhraseShortcutIsNeverAConversation() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("homebot", sid: "14752726")
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.addBySession("14752726", name: "homebot", strict: true))
    let k = m.snapshot.bots[0].key
    let b = try #require(await m.makeShortcut(ShortcutInput(bot: "", entry: true, bots: [k], conversation: true), sign: false))
    #expect(m.snapshot.tokens.first { $0.id == b.tokenId }?.mode == .entry)
    #expect(b.endWord == nil)
  }

  @Test func aReplacementKeepsTheKind() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("homebot", sid: "14752726")
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.addBySession("14752726", name: "homebot", strict: true))
    await m.setLanguages(siriLang: "zh-CN")
    let k = m.snapshot.bots[0].key
    let old = try #require(await m.makeShortcut(ShortcutInput(bot: k, conversation: true), sign: false))
    await m.setLanguages(siriLang: "en-US")
    let made = await m.makeReplacements()
    #expect(made.count == 1)
    let t = try #require(m.snapshot.tokens.first { $0.id == made[0].tokenId })
    #expect(t.replaces == nil && t.mode == .conversation)
    #expect(made[0].endWord == "stop")
  }

  /// "Make it again" on the iPhone step keeps the Shortcut's own language and kind.
  @Test func makeItAgainKeepsLanguageAndKind() {
    var t = token("zh", state: .active, siriLang: "zh-CN")
    t.mode = .conversation
    let d = PhoneDelivery.installed.again(t)
    #expect(d.siriLang == "zh-CN" && d.conversation && d.replaces == "" && !d.entry)
    t.mode = .single
    #expect(PhoneDelivery.gone.again(t).conversation == false)
  }
}
