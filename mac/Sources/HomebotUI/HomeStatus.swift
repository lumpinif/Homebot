// What Home's three status tiles say, from the model's state alone (so it is testable without
// views): the value, one mark of three kinds, and the fix the whole tile performs when something
// is wrong. Every tile has a mark, and a mark is green only for a state that was checked.
import Foundation
import HomebotCore
import HomebotGateway

enum TileMark: Equatable {
  /// Checked and fine.
  case ok
  /// Needs the user; the tile's action is the fix.
  case problem
  /// Nothing to judge yet: not checked, or nothing happened.
  case neutral
}

struct TileState: Equatable {
  var value: String
  var mark: TileMark
  /// The fix the tile performs, shown on the tile; nil when the tile only opens its page.
  var fix: String?
  /// Where the fix goes when it is not the tile's usual page.
  var page: Page? = nil
}

enum HomeStatus {
  /// The Grok Bot key: green only once Grok Bot accepted it in this run. Before a check could run
  /// (it reads a bot, so none exists yet) the tile names the credential instead of a status.
  static func key(_ s: Snapshot, _ T: Tr) -> TileState {
    guard let c = s.credential else { return TileState(value: T.keyNone, mark: .problem, fix: T.openAccount) }
    switch c.access {
    case .ok: return TileState(value: T.accessOk, mark: .ok)
    case .rejected: return TileState(value: T.accessRejected, mark: .problem, fix: T.openAccount)
    case .unchecked: return TileState(value: c.source == .saved ? T.keySaved : T.keyDetected, mark: .neutral)
    }
  }

  /// Shortcuts that answer Siri (active asking Shortcuts); one made but not used yet leads to
  /// the Install step.
  static func shortcuts(_ s: Snapshot, _ T: Tr) -> TileState {
    // Without a usable key no Shortcut can answer, whatever its state: never "working" then.
    // The key tile carries the fix; this one only opens the list.
    if Flow.progress(s)[.account]?.done != true, s.tokens.contains(where: { $0.kind == .ask && $0.state != .retired }) {
      return TileState(value: T.shortcutsNeedKey, mark: .neutral)
    }
    let live = s.tokens.filter { $0.kind == .ask && $0.state == .active }.count
    if live > 0 { return TileState(value: T.fmt(T.shortcutsWorking, ["n": "\(live)"]), mark: .ok) }
    // Made but not answered yet: setup ends with installing it, not with another Shortcut.
    if s.tokens.contains(where: { $0.kind == .ask && $0.state == .pending }) {
      return TileState(value: T.statePending, mark: .problem, fix: T.install, page: .install)
    }
    return TileState(value: T.lastNone, mark: .problem, fix: T.makeOne)
  }

  /// The newest request in the activity store (the gateway's status reads it there).
  static func last(_ st: GatewayStatus?, _ T: Tr) -> TileState {
    guard let at = st?.lastAt, let o = st?.lastOutcome else { return TileState(value: T.lastNone, mark: .neutral) }
    let when = Date(timeIntervalSince1970: at / 1000).formatted(.relative(presentation: .named).locale(T.locale))
    let mark: TileMark = switch outcomeStyle(o) {
    case .success: .ok
    case .neutral: .neutral
    default: .problem
    }
    return TileState(value: "\(T.outcomeLabel(o)) · \(when)", mark: mark)
  }

  /// How an outcome reads: answered, a normal end (said the end word, silence, a choice, a new
  /// start), a refusal or failure, or something to retry.
  static func outcomeStyle(_ o: String) -> BadgeStyle {
    if o == "answered" { return .success }
    if ["end-word", "silence", "chosen", "restart"].contains(o) { return .neutral }
    if ["refused", "auth-failed", "error", "forbidden", "bad-token", "revoked"].contains(o) { return .danger }
    return .warning
  }
}
