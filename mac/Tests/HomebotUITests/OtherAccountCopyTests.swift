// A copy for an iPhone on another Apple Account (S26): it keeps the phrase and replaces nothing;
// without the flag a copy takes the next free phrase; a Shortcut made for this account still
// avoids a phrase in use here, and is never blocked by such a copy.
import Foundation
import Testing

import HomebotCore
import HomebotTestSupport
@testable import HomebotUI

@MainActor
@Suite(.serialized) struct OtherAccountCopyTests {
  @Test func aCopyForAnotherAccountKeepsThePhrase() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("homebot", sid: "14752726")
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.addBySession("14752726", name: "homebot", strict: true))
    let k = m.snapshot.bots[0].key
    let first = try #require(await m.makeShortcut(ShortcutInput(bot: k), sign: false))

    // Flag off: the next free phrase.
    let mine = try #require(await m.makeCopy(first.tokenId, replacing: false))
    #expect(mine.name != first.name)
    #expect(m.snapshot.tokens.first { $0.id == mine.tokenId }?.otherAccount == false)

    // Flag on: the same phrase, nothing replaced, the first one untouched.
    let other = try #require(await m.makeCopy(first.tokenId, replacing: false, otherAccount: true))
    let o = try #require(m.snapshot.tokens.first { $0.id == other.tokenId })
    #expect(o.label == first.name && o.replaces == nil && o.otherAccount)
    #expect(m.snapshot.tokens.first { $0.id == first.tokenId }?.state == .pending)

    // A later Make for this account still avoids the phrase, and can't take it by name.
    let next = try #require(await m.makeShortcut(ShortcutInput(bot: k, replaces: ""), sign: false))
    #expect(next.name != first.name)
    #expect(await m.makeShortcut(ShortcutInput(bot: k, name: first.name, replaces: ""), sign: false) == nil)

    // Replacing the original keeps its phrase: the other account's copy is no clash.
    let again = try #require(await m.makeCopy(first.tokenId))
    #expect(again.name == first.name)
    // Replacing the copy keeps its phrase and the flag.
    let copyAgain = try #require(await m.makeCopy(other.tokenId))
    let c = try #require(m.snapshot.tokens.first { $0.id == copyAgain.tokenId })
    #expect(c.label == first.name && c.otherAccount)
    // The never-used copy it replaced is retired at once (supersedeUnused).
    #expect(m.snapshot.tokens.first { $0.id == other.tokenId }?.state == .retired)
  }
}
