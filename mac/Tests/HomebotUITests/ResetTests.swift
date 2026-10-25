// Settings › Reset everything: the gateway stops and starts again on an empty folder, the app is
// back on the Account step of a first run, and the saved key goes only when asked.
import Foundation
import Testing

import HomebotCore
import HomebotGateway
import HomebotTestSupport
@testable import HomebotUI

@MainActor
@Suite(.serialized) struct AppResetTests {
  /// A model past setup: a key, one bot, a built Shortcut, prefs changed from their defaults.
  func setUp(_ fake: FakeGrokBot) async throws -> AppModel {
    fake.addNamed("homebot", sid: "14752726")
    let m = try await makeModel(fake)
    #expect(await m.saveKey(FakeGrokBot.key))
    #expect(await m.addByName("homebot", confirm: "homebot", strict: true))
    #expect(try #require(await m.makeShortcut(ShortcutInput(bot: "homebot", url: "http://mac.local:8787"), sign: false)).tokenId.count == 12)
    m.setAppearance(.dark)
    m.finishMacHints()
    m.page = .home
    #expect(m.snapshot.credential?.access == .ok)
    return m
  }

  @Test func resetReturnsToTheFirstRunAndKeepsTheKey() async throws {
    let fake = FakeGrokBot()
    let m = try await setUp(fake)
    defer { Task { await m.shutdown() } }
    let sent = fake.requests.filter { $0.method == "POST" && $0.path.hasSuffix("/messages") }.count

    #expect(await m.resetEverything(removeKey: false))
    #expect(m.status?.running == true, "the gateway serves again")
    #expect(m.page == .account)
    #expect(m.snapshot.bots.isEmpty && m.snapshot.tokens.isEmpty)
    #expect(m.build == nil && m.batch.isEmpty && m.draft == nil)
    #expect(m.prefs.appearance == .system && !m.prefs.macHintsDone)
    #expect(m.prefs.languageSeen, "the first run's languages were set again")
    #expect(m.snapshot.credential?.source == .saved, "the key stays unless asked")
    #expect(m.snapshot.credential?.access == .unchecked, "as on a first run: no result until a bot can be read")
    #expect(Flow.startPage(m.snapshot) == .bot)
    #expect(m.toasts.last?.text == m.tr.resetDone)
    #expect(fake.requests.filter { $0.method == "POST" && $0.path.hasSuffix("/messages") }.count == sent, "no bot is messaged")
    // The stores agree with the snapshot after the restart.
    #expect(await m.host.config.bots().isEmpty)
    #expect(await m.host.tokens.list().isEmpty)
  }

  @Test func resetCanRemoveTheKey() async throws {
    let fake = FakeGrokBot()
    let m = try await setUp(fake)
    defer { Task { await m.shutdown() } }
    #expect(await m.resetEverything(removeKey: true))
    #expect(m.snapshot.credential == nil)
    #expect(m.page == .account)
    #expect(Flow.startPage(m.snapshot) == .account)
  }

  @Test func resetDropsTheUndoOfARemovedKey() async throws {
    let fake = FakeGrokBot()
    let m = try await setUp(fake)
    defer { Task { await m.shutdown() } }
    await m.removeKey()
    #expect(m.canUndoRemoveKey)
    #expect(await m.resetEverything(removeKey: false))
    #expect(m.canUndoRemoveKey == false)
    #expect(await m.undoRemoveKey() == false)
    #expect(m.snapshot.credential == nil)
  }
}
