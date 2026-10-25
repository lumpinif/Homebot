// The Shortcuts page's rules: what each row's status column says and the order of the rows.
import HomebotCore

enum ShortcutStatus: CaseIterable, Equatable {
  case working, notUsedYet, needsUpdate, retired, needsKey

  /// A pending Shortcut reads "Not used yet" whether or not it has been tried: it has not
  /// answered yet. "Needs update" only when it can no longer reach Homebot (`Flow.needsUpdate`);
  /// a Shortcut in another language than the default still works and is never marked. Without a
  /// usable key (`keyUsable` false) an active one can't answer, so it is never "working" then.
  static func of(_ t: TokenView, needsUpdate: Bool, keyUsable: Bool = true) -> ShortcutStatus {
    if t.state == .retired { return .retired }
    if needsUpdate { return .needsUpdate }
    if t.state == .active { return keyUsable ? .working : .needsKey }
    return .notUsedYet
  }

  func label(_ T: Tr) -> String {
    switch self {
    case .working: T.stateActive
    case .notUsedYet: T.statePending
    case .needsUpdate: T.stateOutdated
    case .retired: T.stateRetired
    case .needsKey: T.shortcutsNeedKey
    }
  }

  /// The dot: green when working, orange when it needs an update, grey otherwise.
  var ok: Bool? {
    switch self {
    case .working: true
    case .needsUpdate: false
    case .notUsedYet, .retired, .needsKey: nil
    }
  }
}

enum ShortcutList {
  /// Working ones first, then the rest; newest first within each. Retired ones are listed apart.
  static func live(_ tokens: [TokenView]) -> [TokenView] {
    let newest = tokens.filter { $0.state != .retired }.reversed()
    return newest.filter { $0.state == .active } + newest.filter { $0.state != .active }
  }

  static func retired(_ tokens: [TokenView]) -> [TokenView] {
    tokens.filter { $0.state == .retired }.reversed()
  }
}
