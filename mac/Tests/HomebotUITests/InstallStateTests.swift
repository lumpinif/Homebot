// S16: the Install step (this Mac or the iPhone) and the Shortcuts list's rows.
import Foundation
import Testing

import HomebotCore
import HomebotTestSupport
@testable import HomebotUI

@Suite struct InstallStateTests {
  func add(hasFile: Bool = true, signed: Bool = true, opened: Bool = false, onDevice: Bool = false, _ library: [String]?) -> MacAddState {
    InstallState.macAdd(name: "Homebot", hasFile: hasFile, signed: signed, opened: opened, onDevice: onDevice, library: library)
  }

  @Test func addingGoesFromReadyToAdded() {
    #expect(add(["问 Grok Bot"]) == .ready)
    // Clicked "Add to Shortcuts": not there yet (the window is open), then there.
    #expect(add(opened: true, ["问 Grok Bot"]) == .ready)
    #expect(add(opened: true, ["问 Grok Bot", "Homebot"]) == .added)
  }

  @Test func anOlderShortcutWithTheNameIsRemovedFirst() {
    // Adding over it can leave only "Homebot 1/2", so the old one goes first (D3).
    #expect(add(["Homebot"]) == .nameTaken)
    // Once this one is on a device (used or answered), the name is this one.
    #expect(add(onDevice: true, ["Homebot"]) == .added)
  }

  @Test func renamedCopiesAreCaught() {
    #expect(add(opened: true, ["Homebot 1"]) == .renamed("Homebot 1"))
    #expect(add(opened: true, ["Homebot", "Homebot 1"]) == .renamed("Homebot 1"))
    #expect(add(onDevice: true, ["Homebot 2"]) == .renamed("Homebot 2"))
    // Someone else's "Homebot 1" before this one was ever added is not this one's copy.
    #expect(add(["Homebot 1"]) == .ready)
  }

  @Test func withoutAFileOrASignature() {
    #expect(add(hasFile: false, []) == .needsFile)
    #expect(add(signed: false, []) == .needsSigning)
    // Used: its file is gone by design, and it is on a device.
    #expect(add(hasFile: false, onDevice: true, nil) == .added)
  }

  @Test func anUnknownLibraryNeverClaimsTheNameIsTaken() {
    #expect(add(nil) == .ready)
    #expect(add(opened: true, nil) == .ready)
  }

  @Test func theListHidesRetiredAndUninstallableCopies() {
    var withFile = token("file", state: .pending)
    withFile.hasFile = true
    var used = token("used", state: .pending)
    used.usedAt = 5
    let stale = token("stale", state: .pending)
    let rows = ShortcutList.visible([token("old", state: .retired), stale, withFile, used, token("ok", state: .active)])
    #expect(rows.map(\.id) == ["ok", "used", "file"])
  }

  @Test func shortcutsURLsEncodeTheWholeName() {
    #expect(ShortcutsURL.run("Homebot")?.absoluteString == "shortcuts://run-shortcut?name=Homebot")
    #expect(ShortcutsURL.open("Ask A&B=C+D #1")?.absoluteString == "shortcuts://open-shortcut?name=Ask%20A%26B%3DC%2BD%20%231")
    let zh = try? #require(ShortcutsURL.run("居家对话"))
    #expect(zh.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first?.value } == "居家对话")
  }

  @Test func signedFilesAreAppleEncryptedArchives() throws {
    let dir = try shortDir()
    let signed = dir.appendingPathComponent("a.shortcut")
    let plain = dir.appendingPathComponent("b.shortcut")
    try Data("AEA1rest".utf8).write(to: signed)
    try Data("<?xml".utf8).write(to: plain)
    #expect(ShortcutFile.isSigned(signed))
    #expect(!ShortcutFile.isSigned(plain))
    #expect(!ShortcutFile.isSigned(dir.appendingPathComponent("missing.shortcut")))
  }

  @Test func theAnswerIsRemembered() throws {
    var p = AppPrefs()
    p.installTarget = .mac
    p.addedOnMac = ["abc"]
    let data = try JSONEncoder().encode(p)
    let back = try JSONDecoder().decode(AppPrefs.self, from: data)
    #expect(back.installTarget == .mac && back.addedOnMac == ["abc"])
    // An older app.json has neither.
    let old = try JSONDecoder().decode(AppPrefs.self, from: Data(#"{"keepAwake":true}"#.utf8))
    #expect(old.installTarget == nil && old.addedOnMac.isEmpty)
  }
}

@MainActor
@Suite(.serialized) struct InstallModelTests {
  @Test func installFromTheListKeepsLanguageAndKindAndMakesACopyWhenTheFileIsGone() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("homebot", sid: "14752726")
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.addBySession("14752726", name: "homebot", strict: true))
    let k = m.snapshot.bots[0].key
    let first = try #require(await m.makeShortcut(ShortcutInput(bot: k, siriLang: "zh-CN", conversation: true), sign: false))
    let t = try #require(m.snapshot.tokens.first { $0.id == first.tokenId })
    #expect(t.hasFile)
    // Open from the list: the same Shortcut, with its own file.
    m.build = nil
    await m.install(t)
    #expect(m.page == .install)
    #expect(m.build?.tokenId == t.id && m.build?.name == t.label)
    #expect(m.build?.endWord != nil, "a conversation Shortcut names its end word")
    // The file is gone (expired): a new copy has the same phrase, language and kind, and the
    // never-used first copy is retired at once.
    try FileManager.default.removeItem(at: try m.host.tokens.artifactDir(t.id))
    m.builds[t.id] = nil
    await m.refresh()
    #expect(ShortcutList.visible(m.snapshot.tokens).isEmpty, "a never-used copy without its file is hidden")
    let copy = try #require(await m.makeCopy(t.id))
    let c = try #require(m.snapshot.tokens.first { $0.id == copy.tokenId })
    #expect(c.label == t.label && c.siriLang == "zh-CN" && c.mode == .conversation)
    #expect(m.snapshot.tokens.first { $0.id == t.id }?.state == .retired)
    #expect(m.build?.tokenId == copy.tokenId)
  }

  @Test func aFileFromAnEarlierRunIsFoundOnDisk() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("homebot", sid: "14752726")
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.addBySession("14752726", name: "homebot", strict: true))
    await m.setLanguages(appleSigning: true)
    let b = try #require(await m.makeShortcut(ShortcutInput(bot: m.snapshot.bots[0].key), sign: true))
    // A new run knows nothing of this run's builds.
    m.builds = [:]
    await m.refresh()
    #expect(m.snapshot.tokens.first { $0.id == b.tokenId }?.hasFile == true)
    let f = try m.builtFile(b.tokenId)
    #expect(f.name == b.name)
    #expect(!f.signed, "the dev signer only copies: not an Apple archive")
  }

  @Test func theLibraryIsReadOnlyForTheMacPath() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("homebot", sid: "14752726")
    let reads = Box(0)
    let m = try await makeModel(fake, library: { reads.mutate { $0 += 1 }; return ["Homebot"] })
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.addBySession("14752726", name: "homebot", strict: true))
    _ = await m.makeShortcut(ShortcutInput(bot: m.snapshot.bots[0].key), sign: false)
    m.go(.install)
    await m.refresh()
    #expect(reads.value == 0, "no answer yet: nothing is read")
    m.setInstallTarget(.iphone)
    await m.refresh()
    #expect(reads.value == 0)
    m.setInstallTarget(.mac)
    m.libraryAt = .distantPast
    await m.refresh()
    #expect(reads.value >= 1)
    #expect(m.library == ["Homebot"])
    #expect(AppPrefs.load(m.home).installTarget == .mac)
  }

  @Test func aCopyOfANeverUsedReplacementKeepsThePhraseOverTheWorkingOne() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("homebot", sid: "14752726")
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.addBySession("14752726", name: "homebot", strict: true))
    let k = m.snapshot.bots[0].key
    // A works; B replaces it with the same phrase and is never used; B's file goes.
    let a = try #require(await m.makeShortcut(ShortcutInput(bot: k), sign: false))
    #expect(try await m.host.tokens.takeOver(a.tokenId))
    let b = try #require(await m.makeShortcut(ShortcutInput(bot: k, name: a.name, replaces: a.tokenId), sign: false))
    try FileManager.default.removeItem(at: try m.host.tokens.artifactDir(b.tokenId))
    m.builds[b.tokenId] = nil
    await m.refresh()
    // A copy of B takes the phrase over from A, through B.
    let c = try #require(await m.makeCopy(b.tokenId), "the app's phrase check exempts the whole chain")
    #expect(c.name == a.name)
    #expect(m.snapshot.tokens.first { $0.id == b.tokenId }?.state == .retired)
    #expect(m.snapshot.tokens.first { $0.id == a.tokenId }?.state == .active, "A works until the copy answers")
  }

  @Test func installMakesANewCopyWhenTheAddressChanged() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("homebot", sid: "14752726")
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.addBySession("14752726", name: "homebot", strict: true))
    let a = try #require(await m.makeShortcut(ShortcutInput(bot: m.snapshot.bots[0].key, siriLang: "de-DE"), sign: false))
    #expect(try await m.host.tokens.takeOver(a.tokenId))
    m.prefs.builtFor[a.tokenId] = "old-mac.local:8787"
    await m.refresh()
    let t = try #require(m.snapshot.tokens.first { $0.id == a.tokenId })
    #expect(Flow.needsUpdate(t, m.snapshot))
    await m.install(t)
    #expect(m.page == .install)
    let copy = try #require(m.snapshot.tokens.first { $0.id == m.build?.tokenId })
    #expect(copy.id != a.tokenId && copy.label == a.name && copy.siriLang == "de-DE")
    #expect(!Flow.needsUpdate(copy, m.snapshot))
  }

  @Test func addingOnTheMacStopsWhenTheNameIsTaken() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("homebot", sid: "14752726")
    let names = Box<[String]>([])
    let m = try await makeModel(fake, library: { names.value })
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.addBySession("14752726", name: "homebot", strict: true))
    let b = try #require(await m.makeShortcut(ShortcutInput(bot: m.snapshot.bots[0].key), sign: false))
    // The library was not read yet; an old Shortcut has the name.
    names.mutate { $0 = ["Notes", b.name] }
    await m.addOnMac(b.tokenId)
    #expect(!m.prefs.addedOnMac.contains(b.tokenId), "the file is not opened over a Shortcut of the same name")
    #expect(m.library == ["Notes", b.name])
    #expect(InstallState.macAdd(name: b.name, hasFile: true, signed: true, opened: false, onDevice: false, library: m.library) == .nameTaken)
  }

  @Test func aSignedCopyKeepsTheShortcutsSettings() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("homebot", sid: "14752726")
    fake.addNamed("Kitchen", sid: "14752727")
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.addBySession("14752726", name: "homebot", strict: true))
    #expect(await m.addBySession("14752727", name: "Kitchen", strict: true))
    let k = try #require(m.snapshot.bots.first { $0.name == "Kitchen" }).key
    let b = try #require(await m.makeShortcut(ShortcutInput(bot: k, siriLang: "zh-CN", conversation: true), sign: false))
    #expect(!b.signed)
    // "Sign with Apple and make" on the Install step: the click is the consent.
    let copy = try #require(await m.makeCopy(b.tokenId, consent: true))
    #expect(copy.signed && m.snapshot.appleSigning)
    let t = try #require(m.snapshot.tokens.first { $0.id == copy.tokenId })
    #expect(t.bots == [k]); #expect(t.siriLang == "zh-CN"); #expect(t.mode == .conversation); #expect(t.label == b.name)
  }

  @Test func aFirstRunStartsInTheMacLanguage() async throws {
    let fake = FakeGrokBot()
    let m = try await makeModel(fake, uiLang: .zhHans, fresh: true)
    defer { Task { await m.shutdown() } }
    await m.firstRunLanguages()
    #expect(m.snapshot.siriLang == "zh-CN")
    #expect(m.snapshot.phoneLang == .zhHans)
    #expect(m.snapshot.siriLangBefore == nil, "nothing to suggest on a first run")
    // Only once.
    await m.setLanguages(siriLang: "en-US")
    await m.firstRunLanguages()
    #expect(m.snapshot.siriLang == "en-US")
  }
}
