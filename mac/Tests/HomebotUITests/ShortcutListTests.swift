// The Shortcuts page: each row's status and the order of the rows.
import Testing

import HomebotCore
@testable import HomebotUI

@Suite struct ShortcutListTests {
  @Test func statusReadsOneOfFour() {
    var tried = token("p", state: .pending)
    tried.usedAt = 5
    #expect(ShortcutStatus.of(token("a", state: .active), needsUpdate: false) == .working)
    #expect(ShortcutStatus.of(token("p", state: .pending), needsUpdate: false) == .notUsedYet)
    #expect(ShortcutStatus.of(tried, needsUpdate: false) == .notUsedYet, "tried but not answered yet: still not used")
    #expect(ShortcutStatus.of(token("a", state: .active), needsUpdate: true) == .needsUpdate)
    #expect(ShortcutStatus.of(token("r", state: .retired), needsUpdate: true) == .retired)
    // S22: no usable key, nothing answers: an active one is never "working" (grey, not green).
    #expect(ShortcutStatus.of(token("a", state: .active), needsUpdate: false, keyUsable: false) == .needsKey)
    #expect(ShortcutStatus.needsKey.ok == nil)
    #expect(ShortcutStatus.of(token("p", state: .pending), needsUpdate: false, keyUsable: false) == .notUsedYet)
  }

  /// "Needs update" only when the file holds an address that is no longer this Mac's.
  @Test func needsUpdateOnlyWhenTheAddressChanged() {
    let s = Snapshot(gatewayURL: "http://mac.local:8787")
    var t = token("a", state: .active)
    #expect(!Flow.needsUpdate(t, s), "made elsewhere or for a typed address: never judged")
    t.builtFor = "mac.local:8787"
    #expect(!Flow.needsUpdate(t, s))
    t.builtFor = "old-name.local:8787"
    #expect(Flow.needsUpdate(t, s), "the Mac was renamed")
    t.builtFor = "mac.local:9000"
    #expect(Flow.needsUpdate(t, s), "the port changed")
    t.state = .retired
    #expect(!Flow.needsUpdate(t, s))
  }

  @Test func workingFirstThenTheRestNewestFirst() {
    let tokens = [token("a1", state: .active), token("p1", state: .pending), token("r1", state: .retired),
                  token("a2", state: .active), token("p2", state: .pending)]
    #expect(ShortcutList.live(tokens).map(\.id) == ["a2", "a1", "p2", "p1"])
    #expect(ShortcutList.retired(tokens).map(\.id) == ["r1"])
  }
}
