// The app's view model against the fake Grok Bot API in this process: real stores in a short
// temporary folder, the gateway on an ephemeral loopback port, the dev signer. Ported from the
// setup server's API rows (test/setup.test.ts): key, add by name typed twice, the just-created
// check, add by session id, create, rename, remove, Shortcuts and revoke.
import CoreImage
import Foundation
import Testing

import HomebotCore
import HomebotGateway
import HomebotTestSupport
@testable import HomebotUI

/// A short private directory under /tmp (the control socket path must stay under 104 bytes).
func shortDir() throws -> URL {
  let u = URL(fileURLWithPath: "/tmp/hbui-\(Random.hex(bytes: 4))", isDirectory: true)
  try FileUtil.ensurePrivateDir(u)
  return u
}

@MainActor
func makeModel(_ fake: FakeGrokBot, library: (@Sendable () async -> [String]?)? = nil, uiLang: Lang? = nil, fresh: Bool = false, sign: SignFn? = nil, usage: HTTPTransport? = nil) async throws -> AppModel {
  let root = try shortDir()
  var env = AppEnv()
  env.home = root.appendingPathComponent("hb", isDirectory: true)
  env.userHome = root
  env.port = 0
  env.bind = "127.0.0.1"
  env.bdkBaseURL = FakeGrokBot.baseURL
  env.transport = fake
  env.sign = sign ?? { i, o in try FileManager.default.copyItem(atPath: i, toPath: o) }
  env.fakeLoginItem = true
  env.library = library ?? { [] }
  env.uiLang = uiLang
  env.usageTransport = usage
  let home = try Home(root: env.home)
  try home.prepare()
  var prefs = AppPrefs()
  prefs.keepAwake = false
  // Tests start past the first run unless they test it.
  prefs.languageSeen = !fresh
  try prefs.save(home)
  let m = try AppModel(env: env)
  await m.startGateway()
  #expect(m.status?.running == true)
  await m.refresh()
  return m
}

@MainActor
@Suite(.serialized) struct AppModelTests {
  @Test func keyIsCheckedForShapeAndSaved() async throws {
    let fake = FakeGrokBot()
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    #expect(m.snapshot.credential == nil)
    #expect(await m.saveKey("short") == false)
    #expect(m.toasts.last?.text == m.tr.keyInvalid)
    #expect(await m.saveKey("  \(FakeGrokBot.key)\n"))
    #expect(m.snapshot.credential?.source == .saved)
    await m.removeKey()
    #expect(m.snapshot.credential == nil)
  }

  // Undo after Remove: the same key comes back from memory, with nothing pasted.
  @Test func undoRestoresTheRemovedKey() async throws {
    let fake = FakeGrokBot()
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    #expect(m.canUndoRemoveKey == false)
    #expect(await m.saveKey(FakeGrokBot.key))
    await m.removeKey()
    #expect(m.snapshot.credential == nil)
    #expect(m.canUndoRemoveKey)
    #expect(await m.undoRemoveKey())
    #expect(m.snapshot.credential?.source == .saved)
    #expect(try m.host.credentials.savedKey() == FakeGrokBot.key)
    #expect(m.canUndoRemoveKey == false, "one undo")
    #expect(await m.undoRemoveKey() == false)
  }

  @Test func undoIsGoneOnceAnotherKeyIsSaved() async throws {
    let fake = FakeGrokBot()
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    #expect(await m.saveKey("another-test-key-0000"))
    await m.removeKey()
    #expect(m.canUndoRemoveKey)
    #expect(await m.saveKey(FakeGrokBot.key))
    #expect(m.canUndoRemoveKey == false)
    #expect(await m.undoRemoveKey() == false)
    #expect(try m.host.credentials.savedKey() == FakeGrokBot.key, "the new key is never replaced")
  }

  @Test func undoNeverReplacesAKeySavedElsewhere() async throws {
    let fake = FakeGrokBot()
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    #expect(await m.saveKey("another-test-key-0000"))
    await m.removeKey()
    // The CLI saves a key meanwhile, past the model.
    try m.host.credentials.save(key: FakeGrokBot.key)
    #expect(await m.undoRemoveKey() == false)
    #expect(try m.host.credentials.savedKey() == FakeGrokBot.key)
    #expect(m.canUndoRemoveKey == false)
  }

  @Test func addByNameNeedsTheSameNameTwiceAndAnExistingBot() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("House Butler", sid: "14752726")
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)

    #expect(await m.addByName("House Butler", confirm: "House Bulter", strict: true) == false)
    #expect(fake.created.isEmpty)

    // A typo makes Grok Bot create an empty bot: detected, never added.
    #expect(await m.addByName("House Butlr", confirm: "House Butlr", strict: true) == false)
    #expect(fake.created == ["House Butlr"])
    #expect(m.snapshot.bots.isEmpty)
    #expect(m.toasts.last?.text == m.tr.errors("created-new"))

    #expect(await m.addByName(" House Butler ", confirm: "House Butler", strict: false))
    #expect(m.snapshot.bots.map(\.key) == ["house-butler"])
    #expect(m.snapshot.bots.first?.strictEcho == false)
    #expect(m.snapshot.credential?.access == .ok)
    #expect(m.progress[.bot]?.done == true)

    // The same bot twice is refused.
    #expect(await m.addByName("House Butler", confirm: "House Butler", strict: true) == false)
    #expect(m.toasts.last?.text == m.tr.errTaken)
  }

  @Test func justCreatedUnderAKnownNameOffersRemoval() async throws {
    let fake = FakeGrokBot()
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.addBySession("555", name: "Chai", strict: true))
    // "Chai" was renamed in Grok Bot: asking for it by name now creates a new, empty bot.
    #expect(await m.addByName("Chai", confirm: "Chai", strict: true) == false)
    #expect(m.renamedNotice?.key == "chai")
  }

  @Test func sessionIdAdvancedRenameAndRemove() async throws {
    let fake = FakeGrokBot()
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.addBySession("12a", name: "x", strict: true) == false)
    #expect(m.toasts.last?.text == m.tr.errSession)
    #expect(await m.addBySession("777", name: "Küche Bot", strict: true))
    let key = try #require(m.snapshot.bots.first?.key)
    // As setup.ts: NFKD splits the umlaut off, so it becomes a separator.
    #expect(key == "ku-che-bot")
    #expect(await m.renameBot(key, to: "  Kitchen  "))
    #expect(m.snapshot.bots.first?.name == "Kitchen")
    #expect(await m.renameBot(key, to: String(repeating: "x", count: Bot.maxNameLength + 1)) == false)
    #expect(await m.renameBot("nope", to: "y") == false)
    await m.removeBot(key)
    #expect(m.snapshot.bots.isEmpty)
  }

  @Test func createBotAddsANewOrExistingBot() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("Old One", sid: "42")
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.createBot("Fresh Bot"))
    #expect(fake.created == ["Fresh Bot"])
    #expect(await m.createBot("Old One"))
    #expect(m.toasts.last?.text == m.tr.botExisted)
    #expect(Set(m.snapshot.bots.map(\.name)) == ["Fresh Bot", "Old One"])
  }

  @Test func shortcutPreviewMakeLinkAndRevoke() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("homebot", sid: "14752726")
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.addByName("homebot", confirm: "homebot", strict: true))

    let input = ShortcutInput(bot: "homebot", url: "http://mac.local:8787")
    let pv = try await m.preview(input)
    #expect(!pv.name.isEmpty)
    #expect(pv.say.contains(pv.name))

    // Signing needs the stored consent first.
    #expect(await m.makeShortcut(input, sign: true) == nil)
    await m.setLanguages(appleSigning: true)
    let b = try #require(await m.makeShortcut(input, sign: true))
    #expect(b.signed)
    #expect(!b.steps.isEmpty)
    #expect(m.build == b)
    #expect(m.snapshot.tokens.map(\.state) == [.pending])
    #expect(m.snapshot.tokens.first?.hasFile == true)
    #expect(m.progress[.shortcut]?.done == true)
    #expect(m.progress[.install]?.done == false)

    let file = try m.builtFile(b.tokenId).file
    let secret = try #require(DevSeed.token(in: file))
    guard case .ok(let rec, _) = try await m.host.tokens.verify(secret, use: false) else { Issue.record("token in the file not accepted"); return }
    #expect(rec.id == b.tokenId)

    let link = try #require(await m.link(b.tokenId))
    #expect(link.url.hasPrefix("http://mac.local:8787/dl/"))

    await m.revoke(b.tokenId)
    #expect(m.snapshot.tokens.first?.state == .retired)
    #expect(m.build == nil)
    #expect(await m.link(b.tokenId) == nil)
  }

  @Test func entryShortcutPreviewMakeAndEditItsBots() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("拆解师", sid: "14752726")
    fake.addNamed("厨房", sid: "555")
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)
    await m.setLanguages(siriLang: "zh-CN")
    #expect(await m.addBySession("14752726", name: "拆解师", strict: true))
    #expect(await m.addBySession("555", name: "厨房", strict: true))
    let keys = m.snapshot.bots.map(\.key)
    #expect(keys.count == 2)

    // An entry Shortcut needs a bot; with two, the preview has the "which bot?" turn.
    #expect(await m.makeShortcut(ShortcutInput(bot: "", url: "http://mac.local:8787", entry: true, bots: []), sign: false) == nil)
    #expect(m.toasts.last?.text == m.tr.entryNone)
    let input = ShortcutInput(bot: "", url: "http://mac.local:8787", entry: true, bots: keys)
    let pv = try await m.preview(input)
    #expect(pv.name == "家庭助手")
    #expect(pv.exchange.map(\.text) == ["嘿Siri，家庭助手", "问哪个机器人？1 拆解师，2 厨房。", "拆解师", "拆解师。想问什么？"])
    #expect(pv.exchange.map(\.user) == [true, false, true, false])
    #expect(pv.numberOnly.isEmpty)
    let one = try await m.preview(ShortcutInput(bot: "", url: "http://mac.local:8787", entry: true, bots: [keys[1]]))
    #expect(one.exchange.map(\.text) == ["嘿Siri，家庭助手", "厨房。想问什么？"])
    let single = try await m.preview(ShortcutInput(bot: keys[0], url: "http://mac.local:8787"))
    #expect(single.exchange.count == 2 && single.exchange[0].user && !single.exchange[1].user)

    let b = try #require(await m.makeShortcut(input, sign: false))
    let t = try #require(m.snapshot.tokens.first { $0.id == b.tokenId })
    #expect(t.mode == .entry && t.bots == keys && t.state == .pending)
    #expect(m.progress[.shortcut]?.done == true)

    // T4: the set changes in place; never empty.
    #expect(await m.setTokenBots(b.tokenId, [keys[1]]))
    #expect(m.snapshot.tokens.first { $0.id == b.tokenId }?.bots == [keys[1]])
    #expect(await m.setTokenBots(b.tokenId, []) == false)
    #expect(m.snapshot.tokens.first { $0.id == b.tokenId }?.state == .pending, "editing never activates")
  }

  @Test func aCheckOfAnOldKeyNeverMarksTheNewOne() async throws {
    let fake = FakeGrokBot()
    let m = try await makeModel(fake)
    defer { Task { await m.shutdown() } }
    _ = await m.saveKey(FakeGrokBot.key)
    let old = try await m.client()
    // The key is replaced while a request with the old one is still out.
    _ = await m.saveKey("another-test-key-0000")
    _ = try await m.client()
    await m.recordAccess(true, old)
    await m.refresh()
    #expect(m.snapshot.credential?.access == .unchecked)
  }

  @Test func launchChecksAnUncheckedKeyReadOnly() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("House Butler", sid: "14752726")
    let m = try await makeModel(fake)
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.addByName("House Butler", confirm: "House Butler", strict: true))
    let env = m.env
    await m.shutdown()

    // The next launch starts with "not checked yet" and checks once, without a message.
    let before = fake.requests.count
    let next = try AppModel(env: env)
    defer { Task { await next.shutdown() } }
    await next.launch()
    await next.launchCheck?.value
    #expect(next.snapshot.credential?.access == .ok)
    let calls = fake.requests.dropFirst(before)
    #expect(calls.count == 1 && calls.allSatisfy { $0.method == "GET" && $0.path.hasSuffix("/entries") }, "one read, nothing else")
    #expect(fake.posts.isEmpty, "no message is ever sent to a bot")

    // A key already answered is not checked again.
    let after = fake.requests.count
    await next.checkKeyIfUnchecked()
    #expect(fake.requests.count == after)
  }

  @Test func everyNavigationIsANewVisit() async throws {
    let m = try await makeModel(FakeGrokBot())
    defer { Task { await m.shutdown() } }
    let v = m.visit
    m.go(.help)
    m.go(.home)
    m.go(.help)
    #expect(m.page == .help)
    #expect(m.visit == v + 3)
    // S22: a step that is not open lands on the first step not done (no key yet).
    m.go(.shortcut)
    #expect(m.page == .account)
    #expect(m.makeShortcutPage == .account)
  }

  @Test func helpers() {
    #expect(AppModel.isPlausibleKey("test-key-not-a-secret"))
    #expect(!AppModel.isPlausibleKey("has space inside"))
    #expect(!AppModel.isPlausibleKey("短い鍵ですよね"))
    #expect(AppModel.deriveKey("House Butler!", sessionId: "1", taken: []) == "house-butler")
    #expect(AppModel.deriveKey("House Butler", sessionId: "1", taken: ["house-butler"]) == "bot-1")
    #expect(AppModel.deriveKey("小管家", sessionId: "9", taken: []) == "bot-9")
  }
}

@Suite struct QRTests {
  @Test func drawsADecodableCode() throws {
    let text = "http://felix-mac.local:8787/dl/abcdef0123456789"
    let img = try #require(QRCode.image(text))
    #expect(img.width == img.height)
    #expect(img.width >= 21)
    let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil))
    // One pixel per module is too small to read back: scale it up with a quiet zone.
    let ci = CIImage(cgImage: img).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    let padded = ci.composited(over: CIImage(color: .white).cropped(to: ci.extent.insetBy(dx: -32, dy: -32)))
    let found = detector.features(in: padded).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    #expect(found == [text])
  }
}
