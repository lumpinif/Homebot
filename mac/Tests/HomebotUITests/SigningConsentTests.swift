// Consent to sign with Apple (DECISIONS item 24, S19): nothing is sent to Apple before the user
// clicks a button that says so; that click stores the consent, and only Reset everything clears
// it (S21: signing is required, so there is no switch to withdraw it).
import Foundation
import Testing

import HomebotCore
import HomebotGateway
import HomebotTestSupport
@testable import HomebotUI

@MainActor
@Suite(.serialized) struct SigningConsentTests {
  func ready(_ fake: FakeGrokBot, signed: Box<Int>) async throws -> AppModel {
    fake.addNamed("homebot", sid: "14752726")
    let m = try await makeModel(fake, sign: { i, o in
      signed.mutate { $0 += 1 }
      try FileManager.default.copyItem(atPath: i, toPath: o)
    })
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.addByName("homebot", confirm: "homebot", strict: true))
    #expect(!m.snapshot.appleSigning, "a new user has not consented")
    return m
  }

  @Test func noSigningWithoutConsent() async throws {
    let signed = Box(0)
    let m = try await ready(FakeGrokBot(), signed: signed)
    defer { Task { await m.shutdown() } }
    #expect(await m.makeShortcut(ShortcutInput(bot: "homebot"), sign: true) == nil)
    #expect(m.toasts.last?.text == m.tr.errors("signing-consent"))
    #expect(signed.value == 0, "nothing went to the signer")
    #expect(m.snapshot.tokens.isEmpty, "no token is issued for a refused build")
  }

  @Test func theButtonIsTheConsentAndResetClearsIt() async throws {
    let signed = Box(0)
    let m = try await ready(FakeGrokBot(), signed: signed)
    defer { Task { await m.shutdown() } }
    let b = try #require(await m.signAndMake(ShortcutInput(bot: "homebot")))
    #expect(b.signed && signed.value == 1)
    #expect(m.snapshot.appleSigning)
    #expect(await m.host.config.settings.appleSigning == true, "stored, shared with the CLI")

    #expect(await m.resetEverything(removeKey: false))
    #expect(!m.snapshot.appleSigning, "a reset asks for the consent again, as on a first run")
    #expect(await m.host.config.settings.appleSigning != true)
    #expect(await m.addByName("homebot", confirm: "homebot", strict: true))
    #expect(await m.makeShortcut(ShortcutInput(bot: "homebot", name: "Ask homebot"), sign: true) == nil, "refused again")
    #expect(signed.value == 1)
  }

  @Test("a consent that can't be stored builds nothing, unsigned or not, and isn't kept in memory (Codex S19 review)")
  func consentNotStored() async throws {
    let signed = Box(0)
    let m = try await ready(FakeGrokBot(), signed: signed)
    defer { Task { await m.shutdown() } }
    let b = try #require(await m.makeShortcut(ShortcutInput(bot: "homebot"), sign: false))
    let dir = m.host.config.file.deletingLastPathComponent().path
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir) }
    let before = m.snapshot.tokens.count
    #expect(await m.makeCopy(b.tokenId, consent: true) == nil)
    #expect(await m.makeReplacements(consent: true).isEmpty)
    #expect(await m.signAndMake(ShortcutInput(bot: "homebot", name: "Ask homebot")) == nil)
    #expect(signed.value == 0 && m.snapshot.tokens.count == before)
    try await m.host.config.refresh()
    #expect(await m.host.config.settings.appleSigning != true, "the failed write left no consent in memory")
  }
}
