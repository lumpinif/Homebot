// A plain Make adds a Shortcut and replaces nothing; only a replacement the user asks for on one
// Shortcut retires it (DECISIONS item 37). Felix made an English "Grok Bot" from the Shortcut
// step; it replaced his Chinese one, which vanished after the new one's first answer.
import Foundation
import Testing

import HomebotCore
import HomebotTestSupport
@testable import HomebotUI

@MainActor
@Suite(.serialized) struct MakeAddsTests {
  /// What the Shortcut step sends for a bot, with or without a Shortcut the user picked to replace.
  func stepInput(_ m: AppModel, _ k: String, siriLang: String, replacing: String? = nil) -> ShortcutInput {
    ShortcutInput(bot: k, url: "http://mac.local:8787", replaces: Flow.defaultReplaces(m.snapshot, bot: k, requested: replacing), siriLang: siriLang, conversation: true)
  }

  func answer(_ m: AppModel, _ b: ShortcutBuild, _ k: String) async throws {
    let secret = try #require(DevSeed.token(in: try m.builtFile(b.tokenId).file))
    _ = try await m.host.tokens.verify(secret, bot: k)
    try await m.host.tokens.takeOver(b.tokenId)
    await m.refresh()
  }

  @Test func aPlainMakeKeepsTheOldShortcutWorking() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("homebot", sid: "14752726")
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.addBySession("14752726", name: "homebot", strict: true))
    let k = m.snapshot.bots[0].key

    let zh = try #require(await m.makeShortcut(stepInput(m, k, siriLang: "zh-CN"), sign: false))
    try await answer(m, zh, k)

    let en = try #require(await m.makeShortcut(stepInput(m, k, siriLang: "en-US"), sign: false))
    #expect(m.snapshot.tokens.first { $0.id == en.tokenId }?.replaces == nil, "the step adds one")
    try await answer(m, en, k)
    #expect(m.snapshot.tokens.first { $0.id == zh.tokenId }?.state == .active, "the Chinese one keeps working")
    #expect(m.snapshot.tokens.first { $0.id == en.tokenId }?.state == .active)

    // "Make it again" on the Chinese one replaces exactly that one, keeping its phrase.
    let again = try #require(await m.makeShortcut(stepInput(m, k, siriLang: "zh-CN", replacing: zh.tokenId), sign: false))
    #expect(m.snapshot.tokens.first { $0.id == again.tokenId }?.replaces == zh.tokenId)
    #expect(again.name == zh.name)
    try await answer(m, again, k)
    #expect(m.snapshot.tokens.first { $0.id == zh.tokenId }?.state == .retired)
    #expect(m.snapshot.tokens.first { $0.id == en.tokenId }?.state == .active, "the English one is not touched")
  }
}
