// What the window shows: the stores as the UI sees them (the setup page's SetupState), and the
// setup flow's rules — which steps are done, which can be opened, where the window opens. Pure
// values and functions, so the flow is tested without a window (HomebotUITests).
import Foundation
import HomebotCore

public enum Page: String, CaseIterable, Sendable, Hashable {
  case home, account, bot, shortcut, install, shortcuts, settings, help

  /// The four setup steps, in order (DECISIONS item 20; the language step went into the Shortcut
  /// step and Settings, S16 D2).
  public static let steps: [Page] = [.account, .bot, .shortcut, .install]
  public var isStep: Bool { Page.steps.contains(self) }
}

public struct CredentialView: Sendable, Equatable {
  public var source: CredentialSource
  /// Only `ok` after Grok Bot accepted the key; never claimed before a real use (§20.4).
  public var access: AcceptedState
}

public struct BotView: Sendable, Equatable, Identifiable {
  public var key: String
  public var name: String
  public var sessionId: String
  public var strictEcho: Bool
  public var synced: Bool
  public var id: String { key }
}

public struct TokenView: Sendable, Equatable, Identifiable {
  public var id: String
  public var bots: [String]
  public var state: TokenState
  public var label: String
  public var siriLang: String
  public var kind: TokenKind
  public var mode: ShortcutMode?
  public var createdAt: Double
  public var activatedAt: Double?
  public var replaces: String?
  /// The file built in this run is still on disk (it can be shown in Finder or linked).
  public var hasFile: Bool
  /// The gateway address ("host:port") its file was built with, when Homebot built it for its
  /// own address; nil otherwise (made elsewhere, or for an address the user typed).
  public var builtFor: String? = nil
  /// First used (it is on a phone); nil while unused. A used pending Shortcut is waiting for its
  /// first answer, which makes it active and retires what it replaces (DESIGN §7.7).
  public var usedAt: Double? = nil
  /// Its first spoken answer from this Mac, and from another device (an iPhone or a HomePod).
  public var answeredHereAt: Double? = nil
  public var answeredElsewhereAt: Double? = nil
  /// A copy for an iPhone on another Apple Account (S26); it may share its phrase.
  public var otherAccount = false
  public var bot: String { bots.first ?? "" }
  public var waitingForAnswer: Bool { state == .pending && usedAt != nil }
}

public struct Snapshot: Sendable, Equatable {
  public var siriLang: String
  public var phoneLang: Lang
  public var appleSigning: Bool
  public var credential: CredentialView?
  public var login: LoginStatus
  public var bots: [BotView]
  public var tokens: [TokenView]
  public var gatewayURL: String
  /// The default language the user last switched away from in Homebot (AppPrefs), nil if never
  /// or once the suggestion was dismissed.
  public var siriLangBefore: String?
  /// Opt-in usage counts (nil in the store = never asked = off) and the update check (default on).
  public var usageCounts = false
  public var updateCheck = true

  public init(siriLang: String = Langs.defaultSiriLang, phoneLang: Lang = .en, appleSigning: Bool = false, credential: CredentialView? = nil, login: LoginStatus = .none, bots: [BotView] = [], tokens: [TokenView] = [], gatewayURL: String = "http://mac.local:8787", siriLangBefore: String? = nil) {
    self.siriLang = siriLang
    self.phoneLang = phoneLang
    self.appleSigning = appleSigning
    self.credential = credential
    self.login = login
    self.bots = bots
    self.tokens = tokens
    self.gatewayURL = gatewayURL
    self.siriLangBefore = siriLangBefore
  }

  public func bot(_ key: String) -> BotView? { bots.first { $0.key == key } }
  /// Shortcuts that still work or are waiting for their first use.
  public var liveTokens: [TokenView] { tokens.filter { $0.state != .retired } }
}

public struct StepState: Sendable, Equatable {
  public var done: Bool
  public var open: Bool
}

public enum Flow {
  /// The setup page's `progress()`, step by step. A step is open only when every step before it
  /// is done, and a step that is not open is never done: its saved data stays (a bot, a
  /// Shortcut), so its ✓ comes back once the steps before it are done again (a removed key
  /// pasted back).
  public static func progress(_ s: Snapshot) -> [Page: StepState] {
    let account = s.credential.map { $0.access != .rejected } ?? false
    let bot = account && !s.bots.isEmpty
    return [
      .account: StepState(done: account, open: true),
      .bot: StepState(done: bot, open: account),
      .shortcut: StepState(done: bot && s.tokens.contains { $0.state != .retired && $0.kind == .ask }, open: bot),
      // Done once a Shortcut has answered, on this Mac or on the iPhone (S16 D6).
      .install: StepState(done: bot && s.tokens.contains { $0.state == .active && $0.kind == .ask }, open: bot),
    ]
  }

  /// Setup is finished once a Shortcut has answered from the iPhone; from then on the window
  /// opens on Home (§20.6).
  public static func isSetUp(_ s: Snapshot) -> Bool {
    progress(s)[.install]?.done == true
  }

  /// Where the window opens: Home after setup, else the first step still to do.
  public static func startPage(_ s: Snapshot) -> Page {
    let p = progress(s)
    if p[.install]?.done == true { return .home }
    return Page.steps.first { p[$0]?.done == false && p[$0]?.open == true } ?? .shortcut
  }

  /// Steps that are not open yet can't be chosen; every other page always can.
  public static func canOpen(_ page: Page, _ s: Snapshot) -> Bool {
    progress(s)[page]?.open ?? true
  }

  /// Where a request for `page` lands: the page itself when it can be opened, else the first
  /// step not done (always open). Every way into a step goes through here: the sidebar, Home's
  /// tiles, the + and "Make one" buttons, the Shortcuts list's Install, a step's Continue.
  public static func landing(_ page: Page, _ s: Snapshot) -> Page {
    if canOpen(page, s) { return page }
    let p = progress(s)
    return Page.steps.first { p[$0]?.done == false } ?? .account
  }

  /// Where a step's own "Continue" goes.
  public static func next(after page: Page, _ s: Snapshot) -> Page {
    let p = progress(s)
    switch page {
    case .account: return p[.bot]?.open == true ? .bot : .account
    case .bot: return .shortcut
    case .shortcut: return .install
    case .install: return .home
    default: return page
    }
  }

  /// The bot's voice Shortcuts a new one may replace when the user picks one, newest first.
  public static func replaceable(_ s: Snapshot, bot: String) -> [TokenView] {
    s.tokens.filter { $0.bot == bot && $0.state != .retired && $0.kind == .ask }.reversed()
  }

  /// What a new Shortcut replaces: only the one the user asked for ("Make it again", Needs update,
  /// or the Replaces picker), if it is still usable. A plain Make adds one and replaces nothing:
  /// several Shortcuts per bot are normal (DECISIONS item 37).
  public static func defaultReplaces(_ s: Snapshot, bot: String, requested: String?) -> String? {
    let usable = replaceable(s, bot: bot)
    return requested.flatMap { r in usable.contains { $0.id == r } ? r : nil }
  }

  /// Voice Shortcuts an entry Shortcut for `bots` may replace: every bot of theirs is in the set
  /// (T6, a replacement never drops a bot), newest first.
  public static func replaceable(_ s: Snapshot, entryBots bots: [String]) -> [TokenView] {
    s.tokens.filter { $0.state != .retired && $0.kind == .ask && !$0.bots.isEmpty && Set($0.bots).isSubset(of: bots) }.reversed()
  }

  public static func defaultReplaces(_ s: Snapshot, entryBots bots: [String], requested: String?) -> String? {
    let usable = replaceable(s, entryBots: bots)
    return requested.flatMap { r in usable.contains { $0.id == r } ? r : nil }
  }

  /// The optional suggestion right after the user changes the default language (DESIGN §7.3):
  /// voice Shortcuts made in the language left behind, to make in the new one as well. Each is not
  /// retired, all its bots are still added, and no version in the new language (the same bots and
  /// kind) is on its way: in use, waiting for its first answer, or with its file still here to
  /// send; one whose file is gone unused can be made again. The new versions are extra Shortcuts:
  /// the old ones keep working in their language, so this is never a status, only a suggestion,
  /// gone once dismissed (`siriLangBefore` cleared).
  public static func languageSuggestion(_ s: Snapshot) -> [TokenView] {
    let now = Langs.langOfSiri(s.siriLang)
    guard let before = s.siriLangBefore.map(Langs.langOfSiri), before != now else { return [] }
    return s.tokens.filter { t in
      t.kind == .ask && Langs.langOfSiri(t.siriLang) == before && t.state != .retired && !t.bots.isEmpty && t.bots.allSatisfy { s.bot($0) != nil }
        && !s.tokens.contains { v in
          v.id != t.id && v.kind == .ask && v.mode == t.mode && v.bots == t.bots && Langs.langOfSiri(v.siriLang) == now
            && (v.state == .active || v.waitingForAnswer || (v.state == .pending && v.hasFile))
        }
    }
  }

  /// A Shortcut that can no longer reach Homebot: its file holds a gateway address ("host:port")
  /// that is no longer this Mac's (the Mac was renamed, or the port changed). Only for Shortcuts
  /// Homebot built for its own address; one made for a typed address is never judged.
  public static func needsUpdate(_ t: TokenView, _ s: Snapshot) -> Bool {
    guard t.state != .retired, let was = t.builtFor else { return false }
    return was != hostPort(s.gatewayURL)
  }

  /// "host:port" of a gateway URL, as a Shortcut's file holds it.
  public static func hostPort(_ url: String) -> String? {
    guard let c = URLComponents(string: url), let h = c.host, !h.isEmpty else { return nil }
    return c.port.map { "\(h):\($0)" } ?? h
  }
}
