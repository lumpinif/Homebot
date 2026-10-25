// Home's status tiles: every tile has a mark, a mark is green only for a checked state, and the
// last request is whatever the gateway's status reports (read from the activity store).
import Foundation
import Testing

import HomebotCore
import HomebotGateway
@testable import HomebotUI

@Suite struct HomeStatusTests {
  let T = Tr(lang: .en, table: [
    "keyNone": "No key", "accessOk": "Accepted", "accessRejected": "Rejected", "accessUnchecked": "Not checked yet",
    "keySaved": "Key saved on this Mac", "keyDetected": "Grok Bot login on this Mac",
    "openAccount": "Open Account", "lastNone": "None yet", "makeOne": "Make one", "shortcutsWorking": "{n} working",
    "statePending": "Not used yet", "install": "Install", "shortcutsNeedKey": "Waiting for the key",
    "outcome.answered": "Answered", "outcome.silence": "Silence", "outcome.upstream": "Grok Bot problem",
  ])

  func status(lastAt: Double?, lastOutcome: String?) throws -> GatewayStatus {
    var o: [String: Any] = ["running": true, "port": 18787, "bind": "0.0.0.0", "accepted": "unchecked", "awake": true,
                            "textHistory": true, "bots": 1, "probeWait": false, "lab": false]
    if let lastAt { o["lastAt"] = lastAt }
    if let lastOutcome { o["lastOutcome"] = lastOutcome }
    return try JSONDecoder().decode(GatewayStatus.self, from: JSONSerialization.data(withJSONObject: o))
  }

  @Test func keyIsGreenOnlyOnceAccepted() {
    func key(_ a: AcceptedState?) -> TileState {
      HomeStatus.key(Snapshot(credential: a.map { CredentialView(source: .saved, access: $0) }), T)
    }
    #expect(key(.unchecked) == TileState(value: "Key saved on this Mac", mark: .neutral), "an unchecked key is grey and names the credential, never \"Not checked yet\"")
    let login = HomeStatus.key(Snapshot(credential: CredentialView(source: .bdkLogin, access: .unchecked)), T)
    #expect(login == TileState(value: "Grok Bot login on this Mac", mark: .neutral))
    #expect(key(.ok) == TileState(value: "Accepted", mark: .ok))
    #expect(key(.rejected) == TileState(value: "Rejected", mark: .problem, fix: "Open Account"))
    #expect(key(nil) == TileState(value: "No key", mark: .problem, fix: "Open Account"))
  }

  @Test func shortcutsCountOnlyWorkingAskingOnes() {
    let key = CredentialView(source: .saved, access: .ok)
    let none = HomeStatus.shortcuts(Snapshot(tokens: [token("b", state: .active, kind: .probe), token("c", state: .retired)]), T)
    #expect(none == TileState(value: "None yet", mark: .problem, fix: "Make one"))
    // Made but not used yet: the fix is the iPhone step, not another Shortcut.
    let made = HomeStatus.shortcuts(Snapshot(credential: key, tokens: [token("a", state: .pending), token("b", state: .active, kind: .probe)]), T)
    #expect(made == TileState(value: "Not used yet", mark: .problem, fix: "Install", page: .install))
    let one = HomeStatus.shortcuts(Snapshot(credential: key, tokens: [token("a", state: .active), token("b", state: .retired)]), T)
    #expect(one == TileState(value: "1 working", mark: .ok))
    // S22: with the key removed or rejected nothing answers; never "working", never green.
    for c in [nil, CredentialView(source: .saved, access: .rejected)] {
      let keyless = HomeStatus.shortcuts(Snapshot(credential: c, tokens: [token("a", state: .active)]), T)
      #expect(keyless == TileState(value: "Waiting for the key", mark: .neutral))
    }
  }

  @Test func lastRequestAlwaysHasAMark() throws {
    #expect(HomeStatus.last(nil, T) == TileState(value: "None yet", mark: .neutral))
    #expect(HomeStatus.last(try status(lastAt: nil, lastOutcome: nil), T).mark == .neutral)
    let at = Date().addingTimeInterval(-120).timeIntervalSince1970 * 1000
    let answered = HomeStatus.last(try status(lastAt: at, lastOutcome: "answered"), T)
    #expect(answered.mark == .ok && answered.value.hasPrefix("Answered · ") && answered.fix == nil)
    #expect(HomeStatus.last(try status(lastAt: at, lastOutcome: "silence"), T).mark == .neutral)
    #expect(HomeStatus.last(try status(lastAt: at, lastOutcome: "upstream"), T).mark == .problem)
  }

  @Test func outcomeStyles() {
    #expect(HomeStatus.outcomeStyle("answered") == .success)
    #expect(HomeStatus.outcomeStyle("end-word") == .neutral)
    #expect(HomeStatus.outcomeStyle("auth-failed") == .danger)
    #expect(HomeStatus.outcomeStyle("busy") == .warning)
  }
}
