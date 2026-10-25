// S16: the Shortcuts library on this Mac (`shortcuts list`), where an answer was spoken, and a
// copy made again before it was ever used.
import Foundation
import Testing

@testable import HomebotCore

@Suite("Install: library and tokens")
struct InstallCoreTests {
  @Test("`shortcuts list` output: one name per line, spaces, CJK and brackets kept, blank lines skipped")
  func parse() {
    let names = ShortcutsLibrary.parse("问 Grok Bot\nHomebot (kitchen)\n\n居家对话\r\n  \n")
    #expect(names == ["问 Grok Bot", "Homebot (kitchen)", "居家对话"])
  }

  @Test("an exact name, Unicode-normalized; a prefix or another case is not the Shortcut")
  func exact() {
    let names = ["Homebot 1", "homebot", "Cafe\u{301}"]
    #expect(!ShortcutsLibrary.has(names, "Homebot"))
    #expect(ShortcutsLibrary.has(names, "Caf\u{e9}"))
    #expect(ShortcutsLibrary.has(names + ["Homebot"], "Homebot"))
  }

  @Test("copies the Shortcuts app renamed: the name, a space and a number only")
  func renamed() {
    let names = ["Homebot", "Homebot 1", "Homebot 23", "Homebot Two", "Homebot 1a", "Homebot2", "居家对话 1"]
    #expect(ShortcutsLibrary.renamedCopies(names, "Homebot") == ["Homebot 1", "Homebot 23"])
    #expect(ShortcutsLibrary.renamedCopies(names, "居家对话") == ["居家对话 1"])
    #expect(ShortcutsLibrary.renamedCopies(names, "Kitchen").isEmpty)
  }

  @Test("a failing `shortcuts` command is an unknown library, not an empty one")
  func failingCommand() async {
    #expect(await ShortcutsLibrary.list(command: "/usr/bin/false") == nil)
    #expect(await ShortcutsLibrary.list(command: "/nonexistent/shortcuts") == nil)
  }

  @Test("the first answer here and the first from another device are kept, once each")
  func noteAnswer() async throws {
    let clock = Clock(1_000)
    let s = try await tokenStore(now: clock.fn)
    let t = try await s.issue(bots: [grant("chai")], label: "a")
    try await s.noteAnswer(t.id, here: true)
    clock.now = 2_000
    try await s.noteAnswer(t.id, here: true)
    try await s.noteAnswer(t.id, here: false)
    clock.now = 3_000
    try await s.noteAnswer(t.id, here: false)
    let info = try #require(await s.list().first)
    #expect(info.answeredHereAt == 1_000)
    #expect(info.answeredElsewhereAt == 2_000)
    // It changes nothing the token may do.
    #expect(info.state == .pending)
  }

  @Test("making again a copy that was never used retires it, and the new one replaces what it replaced")
  func collapseUnused() async throws {
    let s = try await tokenStore()
    let a = try await s.issue(bots: [grant("chai")], label: "Homebot")
    try await answered(s, a)
    let b = try await s.issue(bots: [grant("chai")], label: "Homebot", replaces: a.id, uniqueLabel: true)
    try await s.supersedeUnused(by: b.id)
    let c = try await s.issue(bots: [grant("chai")], label: "Homebot", replaces: b.id, uniqueLabel: true)
    try await s.supersedeUnused(by: c.id)
    #expect(await s.state(b.id) == .retired)
    #expect(await s.state(a.id) == .active)
    #expect(await s.list().first { $0.id == c.id }?.replaces == a.id)
    // C's first answer retires A.
    try await answered(s, c)
    #expect(await s.state(a.id) == .retired)
  }

  @Test("a copy that is on a phone (used) is not retired by a new copy before an answer")
  func usedCopyStays() async throws {
    let s = try await tokenStore()
    let a = try await s.issue(bots: [grant("chai")], label: "Homebot")
    #expect(try await s.verify(a.token).isOK) // used, not answered yet
    let b = try await s.issue(bots: [grant("chai")], label: "Homebot", replaces: a.id, uniqueLabel: true)
    try await s.supersedeUnused(by: b.id)
    #expect(await s.state(a.id) == .pending)
    #expect(await s.list().first { $0.id == b.id }?.replaces == a.id)
  }

  @Test("a never-used first copy made again replaces nothing")
  func collapseFirst() async throws {
    let s = try await tokenStore()
    let a = try await s.issue(bots: [grant("chai")], label: "Homebot")
    let b = try await s.issue(bots: [grant("chai")], label: "Homebot", replaces: a.id, uniqueLabel: true)
    #expect(await s.state(a.id) == .pending, "not before the new file exists")
    try await s.supersedeUnused(by: b.id)
    #expect(await s.state(a.id) == .retired)
    #expect(await s.list().first { $0.id == b.id }?.replaces == nil)
  }
}

@Suite("Install: never-used copies")
struct UnusedCopyTests {
  @Test("a phrase held by a never-used copy is still taken for another Shortcut")
  func unusedHoldsPhrase() async throws {
    let s = try await tokenStore()
    _ = try await s.issue(bots: [grant("chai")], label: "Homebot")
    await #expect(throws: TokenError.self) { _ = try await s.issue(bots: [grant("tea")], label: "Homebot", uniqueLabel: true) }
  }

  @Test("a used copy still holds its phrase: another Shortcut can't take it")
  func usedHoldsPhrase() async throws {
    let s = try await tokenStore()
    let a = try await s.issue(bots: [grant("chai")], label: "Homebot")
    #expect(try await s.verify(a.token).isOK)
    await #expect(throws: TokenError.self) { _ = try await s.issue(bots: [grant("tea")], label: "Homebot", uniqueLabel: true) }
  }
}
