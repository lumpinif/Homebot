// After the default language changes, Homebot suggests new-language versions of the Shortcuts made
// for the old one. They are extra Shortcuts: the old ones keep working (DESIGN §7.3, S15 D4).
import Foundation
import Testing

import HomebotCore
import HomebotTestSupport
@testable import HomebotUI

@MainActor
@Suite(.serialized) struct LanguageReplacementTests {
  @Test func outdatedIsWhatCanBeRebuiltNow() {
    func t(_ id: String, _ bot: String, _ state: TokenState = .active, differs: Bool = true, replaces: String? = nil) -> TokenView {
      var v = token(id, bot: bot, state: state, siriLang: differs ? "zh-CN" : "en-US")
      v.replaces = replaces
      return v
    }
    var s = Snapshot(bots: [BotView(key: "a", name: "A", sessionId: "1", strictEcho: true, synced: true)], siriLangBefore: "zh-CN")
    s.tokens = [t("old", "a"), t("gone", "removed-bot"), t("dead", "a", .retired, differs: false)]
    #expect(Flow.languageSuggestion(s).map(\.id) == ["old"])
    // A version in the current language is on its way (its file is here): nothing more to offer,
    // whether or not it replaces the old one.
    var new = t("new", "a", .pending, differs: false)
    new.hasFile = true
    s.tokens.append(new)
    #expect(Flow.languageSuggestion(s).isEmpty)
    // Its file is gone unsent: the old one is offered again, so the user is never stuck.
    s.tokens[s.tokens.count - 1].hasFile = false
    #expect(Flow.languageSuggestion(s).map(\.id) == ["old"])
    // In use: on its way for good.
    s.tokens[s.tokens.count - 1].state = .active
    #expect(Flow.languageSuggestion(s).isEmpty)
    // Revoked: offered again.
    s.tokens[s.tokens.count - 1].state = .retired
    #expect(Flow.languageSuggestion(s).map(\.id) == ["old"])
  }

  /// Only the user's own switch of the default suggests anything: one made on purpose in another
  /// language works in it and is never offered. "Not now" dismisses the suggestion.
  @Test func onlyTheLanguageSwitchedAwayFromIsSuggested() {
    func t(_ id: String, _ lang: String, _ bot: String = "a") -> TokenView {
      token(id, bot: bot, state: .active, siriLang: lang)
    }
    var s = Snapshot(bots: ["a", "b"].map { BotView(key: $0, name: $0, sessionId: "1", strictEcho: true, synced: true) })
    s.tokens = [t("zh", "zh-CN"), t("de", "de-DE"), t("en", "en-US", "b")]
    #expect(Flow.languageSuggestion(s).isEmpty, "never switched: a different language alone is no reason")
    s.siriLangBefore = "zh-CN"
    #expect(Flow.languageSuggestion(s).map(\.id) == ["zh"], "switched from Chinese: only the Chinese one")
    s.siriLangBefore = "en-GB"
    #expect(Flow.languageSuggestion(s).isEmpty, "switched between English variants: nothing changed for Siri")
    // Bot a already has an English Shortcut: its Chinese one needs no English version.
    s.tokens.append(t("en-a", "en-US"))
    s.siriLangBefore = "zh-CN"
    #expect(Flow.languageSuggestion(s).isEmpty)
    // A Shortcut in another language than the default is never a status on its row.
    #expect(s.tokens.allSatisfy { ShortcutStatus.of($0, needsUpdate: Flow.needsUpdate($0, s)) == .working })
  }

  @Test func newVersionsAreMadeAndTheOldOnesKeepWorking() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("homebot", sid: "14752726")
    fake.addNamed("kitchen", sid: "555")
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.addBySession("14752726", name: "homebot", strict: true))
    #expect(await m.addBySession("555", name: "kitchen", strict: true))
    let keys = m.snapshot.bots.map(\.key)

    // Two Shortcuts made and in use while Siri spoke Chinese.
    await m.setLanguages(siriLang: "zh-CN")
    var old: [String] = []
    for k in keys {
      let b = try #require(await m.makeShortcut(ShortcutInput(bot: k, url: "http://mac.local:8787"), sign: false))
      let secret = try #require(DevSeed.token(in: try m.builtFile(b.tokenId).file))
      _ = try await m.host.tokens.verify(secret, bot: k)
      try await m.host.tokens.takeOver(b.tokenId) // it answered
      old.append(b.tokenId)
    }
    await m.refresh()
    #expect(m.snapshot.tokens.map(\.state) == [.active, .active])
    #expect(Flow.languageSuggestion(m.snapshot).isEmpty)

    // Siri now speaks English: both are offered, and one action makes both replacements.
    await m.setLanguages(siriLang: "en-US")
    #expect(Flow.languageSuggestion(m.snapshot).map(\.id) == old)
    let made = await m.makeReplacements()
    #expect(made.count == 2)
    #expect(m.batch == made)
    #expect(m.build == made.first)
    for (b, o) in zip(made, old) {
      let t = try #require(m.snapshot.tokens.first { $0.id == b.tokenId })
      #expect(t.replaces == nil && t.bots == m.snapshot.tokens.first { $0.id == o }?.bots && t.state == .pending && t.siriLang == "en-US")
      // The English default phrase, not the Chinese one the old Shortcut had.
      let ascii = t.label.unicodeScalars.allSatisfy { $0.isASCII }
      #expect(ascii, "\(t.label)")
      #expect(!b.signed, "signing stays off, as the user left it")
    }
    #expect(Flow.languageSuggestion(m.snapshot).isEmpty, "nothing is offered twice")
    #expect(await m.makeReplacements().isEmpty)

    // The old ones keep working, also once their new version has answered.
    #expect(m.snapshot.tokens.filter { old.contains($0.id) }.map(\.state) == [.active, .active])
    let secret = try #require(DevSeed.token(in: try m.builtFile(made[0].tokenId).file))
    _ = try await m.host.tokens.verify(secret, bot: keys[0])
    await m.refresh()
    #expect(m.snapshot.tokens.filter { old.contains($0.id) }.map(\.state) == [.active, .active])
    #expect(Flow.languageSuggestion(m.snapshot).isEmpty, "a used replacement is on its way: not offered again")
    try await m.host.tokens.takeOver(made[0].tokenId) // its first answer
    await m.refresh()
    #expect(m.snapshot.tokens.first { $0.id == old[0] }?.state == .active, "a new-language version retires nothing")
    #expect(m.snapshot.tokens.first { $0.id == old[1] }?.state == .active)
    #expect(m.snapshot.tokens.first { $0.id == made[0].tokenId }?.state == .active)
  }

  /// Each Shortcut has its own language, starting as the default; changing the default later
  /// marks nothing. A Shortcut built for this Mac's address needs an update only if it changes.
  @Test func eachShortcutKeepsItsOwnLanguage() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("homebot", sid: "14752726")
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.addBySession("14752726", name: "homebot", strict: true))
    let k = m.snapshot.bots[0].key
    let p = try await m.preview(ShortcutInput(bot: k, siriLang: "zh-CN"))
    #expect(p.siriLang == "zh-CN" && m.snapshot.siriLang == "en-US", "the picked language, not the default")
    let zh = try #require(await m.makeShortcut(ShortcutInput(bot: k, siriLang: "zh-CN"), sign: false))
    let en = try #require(await m.makeShortcut(ShortcutInput(bot: k, replaces: ""), sign: false))
    let tokens = m.snapshot.tokens
    #expect(tokens.first { $0.id == zh.tokenId }?.siriLang == "zh-CN")
    #expect(tokens.first { $0.id == en.tokenId }?.siriLang == "en-US")
    // Built for this Mac's own address: recorded, and fine while it stays the same.
    let t = try #require(tokens.first { $0.id == en.tokenId })
    #expect(t.builtFor == Flow.hostPort(m.snapshot.gatewayURL))
    #expect(!Flow.needsUpdate(t, m.snapshot))
    // Switching the default to Chinese suggests nothing: the bot already has the Chinese one made
    // on purpose. No row is ever marked for its language.
    await m.setLanguages(siriLang: "zh-CN")
    #expect(Flow.languageSuggestion(m.snapshot).isEmpty)
    #expect(m.snapshot.tokens.allSatisfy { !Flow.needsUpdate($0, m.snapshot) })
  }

  @Test func oneRowUpdatesOnlyItself() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("homebot", sid: "14752726")
    fake.addNamed("kitchen", sid: "555")
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.addBySession("14752726", name: "homebot", strict: true))
    #expect(await m.addBySession("555", name: "kitchen", strict: true))
    await m.setLanguages(siriLang: "zh-CN")
    var ids: [String] = []
    for k in m.snapshot.bots.map(\.key) {
      ids.append(try #require(await m.makeShortcut(ShortcutInput(bot: k, url: "http://mac.local:8787"), sign: false)).tokenId)
    }
    await m.setLanguages(siriLang: "en-US")
    let made = await m.makeReplacements([ids[1]])
    #expect(made.count == 1)
    #expect(m.snapshot.tokens.first { $0.id == made[0].tokenId }?.bots == m.snapshot.tokens.first { $0.id == ids[1] }?.bots)
    #expect(Flow.languageSuggestion(m.snapshot).map(\.id) == [ids[0]])
    // "Not now": the suggestion goes away, and stays away after a refresh.
    m.dismissLanguageSuggestion()
    #expect(Flow.languageSuggestion(m.snapshot).isEmpty)
    await m.refresh()
    #expect(Flow.languageSuggestion(m.snapshot).isEmpty)
    // A single build in the usual way ends the batch.
    #expect(m.batch.count == 1)
    _ = await m.makeShortcut(ShortcutInput(bot: m.snapshot.bots[0].key, url: "http://mac.local:8787"), sign: false)
    #expect(m.batch.isEmpty)
  }

  @Test func theBatchSurvivesItsShownOneAndRunsOneAtATime() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("homebot", sid: "14752726")
    fake.addNamed("kitchen", sid: "555")
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.addBySession("14752726", name: "homebot", strict: true))
    #expect(await m.addBySession("555", name: "kitchen", strict: true))
    await m.setLanguages(siriLang: "zh-CN")
    for k in m.snapshot.bots.map(\.key) {
      _ = try #require(await m.makeShortcut(ShortcutInput(bot: k, url: "http://mac.local:8787"), sign: false))
    }
    await m.setLanguages(siriLang: "en-US")
    // Two runs started together: the second makes nothing instead of overwriting the first's batch.
    async let a = m.makeReplacements()
    async let b = m.makeReplacements()
    let (ra, rb) = await (a, b)
    #expect([ra.count, rb.count].sorted() == [0, 2])
    #expect(m.batch.count == 2)
    // The shown one revoked: the iPhone step moves to the one left.
    let shown = try #require(m.build)
    await m.revoke(shown.tokenId)
    #expect(m.batch.count == 1)
    #expect(m.build == m.batch.first)
  }
}
