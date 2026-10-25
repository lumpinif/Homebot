// The setup state machine (web/src/app/setup.tsx progress(), DESIGN §20.6): which steps are done
// and open, where the window opens, where Continue goes, and which Shortcut a new one replaces.
import Foundation
import Testing

import HomebotCore
@testable import HomebotUI

func token(_ id: String, bot: String = "homebot", state: TokenState, kind: TokenKind = .ask, siriLang: String = "en-US") -> TokenView {
  TokenView(id: id, bots: [bot], state: state, label: "Ask \(bot)", siriLang: siriLang, kind: kind, mode: nil, createdAt: 0, activatedAt: nil, replaces: nil, hasFile: false)
}

let oneBot = [BotView(key: "homebot", name: "homebot", sessionId: "1", strictEcho: true, synced: true)]

@Suite struct FlowTests {
  @Test func fourStepsInstallLast() {
    // S16 D2: the language step went into the Shortcut step and Settings.
    #expect(Page.steps == [.account, .bot, .shortcut, .install])
  }

  @Test func freshStartsAtAccountWithLaterStepsClosed() {
    let s = Snapshot()
    let p = Flow.progress(s)
    #expect(p[.account] == StepState(done: false, open: true))
    #expect(p[.bot]?.open == false)
    #expect(p[.shortcut]?.open == false)
    #expect(p[.install]?.open == false)
    #expect(Flow.startPage(s) == .account)
    #expect(!Flow.canOpen(.bot, s))
    #expect(Flow.canOpen(.home, s))
    #expect(Flow.canOpen(.settings, s))
  }

  @Test func aRejectedKeyIsNotDone() {
    var s = Snapshot(credential: CredentialView(source: .saved, access: .rejected))
    #expect(Flow.progress(s)[.account]?.done == false)
    #expect(Flow.progress(s)[.bot]?.open == false)
    s.credential?.access = .unchecked
    #expect(Flow.progress(s)[.account]?.done == true)
    #expect(Flow.startPage(s) == .bot)
  }

  @Test func aBotOpensTheRest() {
    let s = Snapshot(credential: CredentialView(source: .saved, access: .ok), bots: oneBot)
    let p = Flow.progress(s)
    #expect(p[.shortcut] == StepState(done: false, open: true))
    #expect(p[.install] == StepState(done: false, open: true))
    #expect(Flow.startPage(s) == .shortcut)
  }

  @Test func pendingShortcutWaitsForInstallThenActiveOpensHome() {
    var s = Snapshot(credential: CredentialView(source: .saved, access: .ok), bots: oneBot, tokens: [token("a", state: .pending)])
    #expect(Flow.progress(s)[.shortcut]?.done == true)
    #expect(Flow.progress(s)[.install]?.done == false)
    #expect(Flow.startPage(s) == .install)
    #expect(!Flow.isSetUp(s))
    // An answer on this Mac or on the iPhone makes it active and finishes setup (S16 D6).
    s.tokens = [token("a", state: .active)]
    #expect(Flow.isSetUp(s))
    #expect(Flow.startPage(s) == .home)
  }

  @Test func withoutAKeyLaterStepsAreClosedAndNeverDone() {
    // S22: the key removed, a bot and a working Shortcut still saved.
    var s = Snapshot(bots: oneBot, tokens: [token("a", state: .active)])
    let p = Flow.progress(s)
    for step in [Page.bot, .shortcut, .install] { #expect(p[step] == StepState(done: false, open: false)) }
    #expect(!Flow.isSetUp(s))
    #expect(Flow.startPage(s) == .account)
    #expect(Flow.landing(.shortcut, s) == .account)
    #expect(Flow.landing(.install, s) == .account)
    #expect(Flow.landing(.shortcuts, s) == .shortcuts)
    // The data stayed: the key back brings every ✓ back.
    s.credential = CredentialView(source: .saved, access: .unchecked)
    #expect(Flow.isSetUp(s))
    #expect(Flow.progress(s)[.bot] == StepState(done: true, open: true))
  }

  @Test func withoutABotShortcutAndInstallLandOnBot() {
    let s = Snapshot(credential: CredentialView(source: .saved, access: .ok), tokens: [token("a", state: .pending)])
    #expect(Flow.progress(s)[.shortcut] == StepState(done: false, open: false))
    #expect(Flow.landing(.shortcut, s) == .bot)
    #expect(Flow.landing(.install, s) == .bot)
    #expect(Flow.landing(.account, s) == .account)
  }

  @Test func retiredAndDeviceShortcutsDoNotCount() {
    let s = Snapshot(credential: CredentialView(source: .saved, access: .ok), bots: oneBot, tokens: [token("r", state: .retired), token("p", state: .active, kind: .probe)])
    let p = Flow.progress(s)
    #expect(p[.shortcut]?.done == false)
    #expect(p[.install]?.done == false)
  }

  @Test func continueGoesToTheNextOpenStep() {
    let none = Snapshot()
    #expect(Flow.next(after: .account, none) == .account)
    let keyed = Snapshot(credential: CredentialView(source: .saved, access: .ok))
    #expect(Flow.next(after: .account, keyed) == .bot)
    #expect(Flow.next(after: .bot, keyed) == .shortcut)
    #expect(Flow.next(after: .shortcut, keyed) == .install)
    #expect(Flow.next(after: .install, keyed) == .home)
    #expect(Flow.next(after: .settings, keyed) == .settings)
  }

  @Test func defaultReplacesIsTheWorkingOneOrAUsableRequest() {
    let s = Snapshot(bots: oneBot, tokens: [token("old", state: .active), token("new", state: .active), token("wait", state: .pending), token("gone", state: .retired), token("other", bot: "x", state: .active)])
    #expect(Flow.defaultReplaces(s, bot: "homebot", requested: nil) == "new")
    #expect(Flow.defaultReplaces(s, bot: "homebot", requested: "wait") == "wait")
    #expect(Flow.defaultReplaces(s, bot: "homebot", requested: "gone") == nil)
    #expect(Flow.defaultReplaces(s, bot: "homebot", requested: "other") == nil)
    #expect(Flow.defaultReplaces(s, bot: "x", requested: nil) == "other")
    #expect(Flow.defaultReplaces(Snapshot(), bot: "homebot", requested: nil) == nil)
  }

  @Test func entryReplacesOnlyWhatItCoversAndKeepsPerBotShortcuts() {
    var entry = token("entry", state: .active)
    entry.bots = ["a", "b"]
    entry.mode = .entry
    let s = Snapshot(tokens: [token("a1", bot: "a", state: .active), token("c1", bot: "c", state: .active), entry, token("dev", bot: "a", state: .active, kind: .probe)])
    #expect(Flow.replaceable(s, entryBots: ["a", "b"]).map(\.id) == ["entry", "a1"], "a token for a bot outside the set, or a test token, is never offered")
    #expect(Flow.defaultReplaces(s, entryBots: ["a", "b"], requested: nil) == "entry", "the per-bot Shortcut stays by default")
    #expect(Flow.defaultReplaces(s, entryBots: ["a"], requested: nil) == nil, "a narrower set never replaces the wider one")
    #expect(Flow.defaultReplaces(s, entryBots: ["a", "b"], requested: "a1") == "a1")
    #expect(Flow.defaultReplaces(s, entryBots: ["a", "b"], requested: "c1") == nil)
  }
}
