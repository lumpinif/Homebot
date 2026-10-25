// The app's model: owns the gateway in-process (DESIGN §20.2) and does what the setup page's
// loopback API did (src/server/setup.ts), now as direct calls on the same stores and locks the
// CLI uses. Every action re-reads the stores and returns a fresh snapshot; a poll keeps status,
// Shortcut states and activity live while the window is open.
import AppKit
import Foundation
import HomebotCore
import HomebotGateway

/// A failure the UI explains with a catalog line (the setup page's error codes, plus the app's).
public struct AppError: Error, Equatable, CustomStringConvertible {
  public let code: String
  public var name: String?
  public init(_ code: String, name: String? = nil) {
    self.code = code
    self.name = name
  }
  public var description: String { code }
}

public struct Toast: Identifiable, Equatable, Sendable {
  public enum Kind: Sendable { case success, error, info }
  public let id = UUID()
  public var text: String
  public var kind: Kind
}

/// What a Shortcut preview or build is for: the setup page's request body.
public struct ShortcutInput: Equatable, Sendable {
  public var bot: String
  public var name: String?
  public var url: String?
  public var replaces: String?
  /// One phrase for `bots` (DESIGN §20.5); `bot` is unused then.
  public var entry: Bool
  /// The entry Shortcut's bots, in menu order.
  public var bots: [String]
  /// This Shortcut's language (its phrase, prompt and voice); nil: the default language.
  public var siriLang: String?
  /// Keep listening after each answer (DESIGN §18); never with `entry`.
  public var conversation: Bool
  /// For an iPhone on another Apple Account (S26): it may keep a phrase in use here.
  public var otherAccount = false
  public init(bot: String, name: String? = nil, url: String? = nil, replaces: String? = nil, entry: Bool = false, bots: [String] = [], siriLang: String? = nil, conversation: Bool = false, otherAccount: Bool = false) {
    self.otherAccount = otherAccount
    self.siriLang = siriLang
    self.conversation = conversation
    self.bot = bot
    self.name = name
    self.url = url
    self.replaces = replaces
    self.entry = entry
    self.bots = bots
  }
}

/// A Shortcut step opened from elsewhere (the Shortcuts list): what to preselect. Applied once.
public struct ShortcutDraft: Equatable, Sendable {
  public var bot: String?
  public var replaces: String?
  public var entry: Bool
  /// The Shortcut's language; nil: the default.
  public var siriLang: String?
  public var conversation: Bool
  public init(bot: String? = nil, replaces: String? = nil, entry: Bool = false, siriLang: String? = nil, conversation: Bool = false) {
    self.conversation = conversation
    self.bot = bot
    self.replaces = replaces
    self.entry = entry
    self.siriLang = siriLang
  }
}

public struct PhraseProblemView: Equatable, Sendable, Identifiable {
  public var code: String
  public var text: String
  public var blocking: Bool
  public var id: String { code }
}

public struct ShortcutPreview: Equatable, Sendable {
  public var name: String
  public var prompt: String
  public var siriLang: String
  /// What the user says, in the Siri language: "Hey Siri, <name>".
  public var say: String
  public var alternatives: [String]
  public var problems: [PhraseProblemView]
  /// The spoken start of the exchange, the user's lines and Siri's, in order (for an entry
  /// Shortcut it includes the "which bot?" turn).
  public var exchange: [EntryPreview.Line] = []
  /// Entry Shortcut: names that can be chosen by number only (§20.5 rule 2).
  public var numberOnly: [String] = []
  public var blocking: Bool { problems.contains { $0.blocking } }
}

extension ShortcutInput {
  /// The phrase as checked and built: runs of white space become one space, ends are trimmed, and
  /// an empty phrase is none. The text field itself keeps what was typed.
  static func phrase(_ typed: String) -> String? {
    let p = typed.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    return p.isEmpty ? nil : p
  }
}

public struct ShortcutBuild: Equatable, Sendable {
  public var tokenId: String
  public var name: String
  public var signed: Bool
  public var steps: [String]
  /// The gateway's host and port, as the iPhone asks to connect to it.
  public var host = ""
  /// "Hey Siri, <phrase>" in the Siri language.
  public var say = ""
  /// What the Shortcut asks when it runs ("What would you like to ask homebot?").
  public var prompt = ""
  /// A conversation Shortcut's end word, in its Siri language; nil for the others.
  public var endWord: String?
}

public struct DownloadLink: Equatable, Sendable {
  public var url: String
  public var expiresAt: Double
}

/// A bot that Grok Bot just created under a name already in Homebot (§20.7): the bot in Homebot
/// was probably renamed in Grok Bot. The UI offers to remove it.
public struct RenamedBotNotice: Equatable, Sendable, Identifiable {
  public var key: String
  public var name: String
  public var id: String { key }
}

@MainActor
@Observable
public final class AppModel {
  public let env: AppEnv
  public let home: Home
  public let host: GatewayHost
  let loginItems: LoginItems

  public private(set) var snapshot = Snapshot()
  public private(set) var loaded = false
  public private(set) var status: GatewayStatus?
  /// Set when the gateway could not start (another owner, port taken).
  public private(set) var startFailed = false
  public private(set) var activity: [ActivityRecord] = []
  public internal(set) var prefs: AppPrefs
  public private(set) var tr: Tr
  public private(set) var loginItem: LoginItemState = .off
  public private(set) var loginItemError: LoginItemError?
  public var toasts: [Toast] = []
  public var page: Page = .account
  /// The Shortcut made in this visit, shown in the iPhone step.
  public var build: ShortcutBuild?
  /// Shortcuts made together (language replacements); `build` is the one the iPhone step shows.
  public var batch: [ShortcutBuild] = []
  /// Replacements are being made: one run at a time, so two never overwrite each other's batch.
  public private(set) var replacing = false
  /// A Shortcut step opened from the Shortcuts list (a replacement, or the entry Shortcut).
  public var draft: ShortcutDraft?
  public var renamedNotice: RenamedBotNotice?
  /// The Shortcuts library on this Mac, read while the Install page shows the This Mac path; nil
  /// when unknown.
  public private(set) var library: [String]?
  var libraryAt = Date.distantPast

  /// Shortcut files built by this run, by token id (the setup server's `builds`).
  var builds: [String: (file: URL, name: String, baseUrl: String, signed: Bool)] = [:]
  var poll: Task<Void, Never>?
  /// Usage counts and the update check (Usage.swift): at launch, then every few hours.
  let usage: UsageClient
  var usageTicker: Task<Void, Never>?
  /// A newer release found by the daily update check.
  public private(set) var update: LatestRelease?
  /// The launch-time key check (tests wait on it).
  var launchCheck: Task<Void, Never>?
  @ObservationIgnored var catalogFallback: [Lang: [String: String]]?
  /// The Bonjour name (it runs scutil), read off the main actor at most every 30 s.
  var hostName = ""
  var hostNameAt = Date.distantPast
  var refreshes = 0
  /// Changes on every navigation: an old step's late "done" can't move a newer visit on.
  public private(set) var visit = 0

  /// Where this copy runs from: outside Applications the window says to move it (§20.11 B1).
  public let placement: AppPlacement
  /// The TypeScript version's folder, if one is there and not imported yet (read only; §20.4).
  public private(set) var legacy: TSImport.Preview?
  /// Sessionless Shortcuts of the old folder the user chose to keep (T2).
  public var importKeep: Set<String> = []
  public private(set) var importing = false
  /// Reset everything is running (Settings).
  public private(set) var resetting = false
  /// The key the Account step's Remove deleted, for its Undo. Only in this process: never
  /// written, never logged; gone once a key is saved or Reset everything runs.
  private var removedKey: String?
  public var canUndoRemoveKey: Bool { removedKey != nil }
  /// Watches the app's effective appearance for the Automatic icon (`followAppearance`).
  @ObservationIgnored private var appearanceWatch: NSKeyValueObservation?

  public init(env: AppEnv) throws {
    self.env = env
    home = try Home(root: env.home)
    try home.prepare()
    var p = AppPrefs.load(home)
    if let a = env.appearance { p.appearance = a }
    if let i = env.appIcon { p.icon = i }
    prefs = p
    host = GatewayHost(GatewayOptions(home: home, userHome: env.userHome, port: env.port, bind: env.bind, bdkBaseURL: env.bdkBaseURL, transport: env.transport, keepAwake: p.keepAwake))
    placement = env.placement ?? AppPlacement.of(Bundle.main.bundleURL)
    if env.fakeLoginItem {
      let fake = FakeLoginItems()
      fake.translocated = placement == .translocated
      loginItems = fake
    } else {
      loginItems = SystemLoginItems()
    }
    let online = !env.dev && env.home == nil
    usage = UsageClient(home: home, transport: env.usageTransport ?? (online ? EphemeralTransport() : OfflineTransport()))
    tr = Tr(lang: .en, table: [:])
    tr = loadTr(env.uiLang ?? L10n.preferred())
  }

  // MARK: launch and refresh

  public func launch() async {
    lookForLegacy()
    await startGateway()
    if env.seed != .none { await DevSeed.run(self, level: env.seed) }
    await refresh()
    if env.uiLang == nil, let saved = try? await uiLangSetting() { tr = loadTr(saved) }
    if let t = env.installTarget { prefs.installTarget = t }
    await firstRunLanguages()
    if env.page == "shortcut-entry" {
      // Dev only: the Shortcut step with the one-phrase Shortcut chosen.
      draft = ShortcutDraft(entry: true)
      page = .shortcut
    } else if let p = env.page.flatMap(Page.init(rawValue:)) {
      page = p
    } else {
      page = Flow.startPage(snapshot)
    }
    loaded = true
    applyAppearance()
    // A key not checked in this run yet is checked once, in the background, so Home says
    // whether Grok Bot accepts it instead of "Not checked yet". Read-only: never a message.
    launchCheck = Task { [weak self] in await self?.checkKeyIfUnchecked() }
    if env.dev && env.clickImport { await importLegacy() }
    usageTicker?.cancel()
    usageTicker = Task { [weak self] in
      while !Task.isCancelled {
        await self?.usageTick()
        try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
      }
    }
    poll?.cancel()
    poll = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard let self else { return }
        await self.refresh()
      }
    }
  }

  public func startGateway() async {
    do {
      try await host.start()
      startFailed = false
    } catch {
      startFailed = true
      if env.dev { FileHandle.standardError.write(Data("Homebot: the gateway did not start: \(error)\n".utf8)) }
    }
    await host.setKeepAwake(prefs.keepAwake)
    status = await host.status()
  }

  /// Stop serving (Quit). The owner lock and the listener are released by the kernel anyway when
  /// the process exits; this lets the activity writer flush first.
  public func shutdown() async {
    poll?.cancel()
    usageTicker?.cancel()
    // An import in progress finishes (or rolls back) first: quitting in the middle would leave
    // the old folder marked as moved with nothing copied (Codex S5 review).
    while importing || resetting { try? await Task.sleep(nanoseconds: 20_000_000) }
    await host.stop()
  }

  func uiLangSetting() async throws -> Lang? {
    try await host.config.refresh()
    return Lang.from(await host.config.settings.uiLang)
  }

  public func refresh() async {
    // A refresh that started before a newer one (or before an action changed state and
    // refreshed) must not install what it read: the newer one has fresher data.
    refreshes += 1
    let mine = refreshes
    let config = host.config
    let tokens = host.tokens
    try? await config.refresh()
    try? await host.state.refresh()
    try? await tokens.refresh()
    let s = await config.settings
    let cred = try? host.credentials.resolve()
    _ = await host.credentialStatus.observe(cred)
    let access = await host.credentialStatus.state
    var bots: [BotView] = []
    for b in await config.bots() {
      bots.append(BotView(key: b.key, name: b.name, sessionId: b.sessionId, strictEcho: b.strictEcho, synced: await host.state.cursor(b.key) != nil))
    }
    let siriLang = Lang(rawValue: Langs.langOfSiri(s.siriLang ?? Langs.defaultSiriLang).rawValue)!.info.siri
    let fm = FileManager.default
    let list = await tokens.list()
    let views = list.map { t in
      TokenView(
        id: t.id, bots: t.bots.map(\.key), state: t.state, label: t.label, siriLang: t.siriLang ?? Langs.defaultSiriLang,
        kind: t.kind ?? .ask, mode: t.mode, createdAt: t.createdAt, activatedAt: t.activatedAt, replaces: t.replaces,
        hasFile: t.state == .pending && t.usedAt == nil && (builds[t.id].map { fm.fileExists(atPath: $0.file.path) } ?? (diskFile(t.id) != nil)),
        builtFor: prefs.builtFor[t.id],
        usedAt: t.usedAt, answeredHereAt: t.answeredHereAt, answeredElsewhereAt: t.answeredElsewhereAt, otherAccount: t.otherAccount == true)
    }
    let st = await host.status()
    let port = st.running ? st.port : (env.port ?? s.port)
    if hostName.isEmpty || Date().timeIntervalSince(hostNameAt) > 30 {
      hostName = await Task.detached { ShortcutMaker.localHostName() }.value
      hostNameAt = Date()
    }
    var next = Snapshot(
      siriLang: siriLang, phoneLang: Lang.from(s.phoneLang) ?? .en, appleSigning: s.appleSigning == true,
      credential: cred.map { CredentialView(source: $0.source, access: access) }, login: host.credentials.loginStatus,
      bots: bots, tokens: views, gatewayURL: "http://\(hostName).local:\(port)", siriLangBefore: prefs.siriLangBefore)
    next.usageCounts = s.usageCounts == true
    next.usageAsked = s.usageCounts != nil
    next.updateCheck = s.updateCheck != false
    let recent = st.running ? ((try? await host.activity.recent(limit: 200)) ?? activity) : []
    guard mine == refreshes else { return }
    if next != snapshot { snapshot = next }
    if st != status { status = st }
    if recent != activity { activity = recent }
    loginItem = loginItems.state
    // A step that closed under the user (the key removed or rejected) is not left open on
    // screen: the window moves to the first step not done.
    if loaded, page.isStep, !Flow.canOpen(page, snapshot) {
      page = Flow.landing(page, snapshot)
      visit += 1
    }
    // A Shortcut revoked, or its bot removed, has nothing left to deliver.
    if let b = build, !snapshot.tokens.contains(where: { $0.id == b.tokenId && $0.state != .retired }) { build = nil }
    batch.removeAll { b in !snapshot.tokens.contains { $0.id == b.tokenId && $0.state != .retired } }
    if build == nil { build = batch.first }
    await readLibrary()
  }

  /// Reads the Shortcuts library every two seconds while the Install page shows the This Mac path.
  func readLibrary() async {
    guard page == .install, prefs.installTarget == .mac, build != nil else { return }
    guard Date().timeIntervalSince(libraryAt) >= 2 else { return }
    libraryAt = Date()
    let names = await env.library()
    if names != library { library = names }
  }

  // MARK: text

  /// Text in the iPhone's language, for the "On your iPhone" guide (it names iOS settings as the
  /// iPhone shows them).
  var phoneTr: Tr {
    let lang = snapshot.phoneLang
    if lang == tr.lang { return tr }
    if let t = phoneTrCache, t.lang == lang { return t }
    let t = loadTr(lang)
    phoneTrCache = t
    return t
  }

  @ObservationIgnored private var phoneTrCache: Tr?

  func loadTr(_ lang: Lang) -> Tr {
    let t = L10n.load(lang)
    if !t.table.isEmpty { return t }
    // Outside an app bundle (swift run, tests): the catalog from the source tree. Debug only, so a
    // release binary carries no path of the machine it was built on.
    #if DEBUG
    if catalogFallback == nil {
      let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../App/Localizable.xcstrings").standardized
      catalogFallback = (try? L10n.catalog(src)) ?? [:]
    }
    #endif
    return Tr(lang: lang, table: catalogFallback?[lang] ?? [:], fallback: catalogFallback?[.en] ?? [:])
  }

  public func toast(_ text: String, _ kind: Toast.Kind = .success) {
    let t = Toast(text: text, kind: kind)
    // The same message again (a button clicked twice) replaces the one shown, never stacks.
    toasts.removeAll { $0.text == text && $0.kind == kind }
    toasts.append(t)
    if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
    // Long errors (what to do next, e.g. delete an empty bot) stay until they can be read.
    let ms: UInt64 = kind == .error ? UInt64(max(6000, min(15000, text.count * 70))) : 2400
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: ms * 1_000_000)
      self?.toasts.removeAll { $0.id == t.id }
    }
  }

  /// A failure as the user reads it: the catalog line for known codes, never a key or a body.
  public func message(_ error: Error) -> String {
    switch error {
    case let e as AppError:
      switch e.code {
      case "key-invalid": return tr.keyInvalid
      case "not-found": return tr.errNotFound
      case "taken": return tr.errTaken
      case "name": return tr.errName
      case "session": return tr.errSession
      case "gateway-url": return tr.errGatewayUrl
      case "entry-none": return tr.entryNone
      default: return tr.errors(e.code) ?? tr.failed
      }
    case let e as BdkError:
      switch e.kind {
      case .auth: return tr.errors("auth") ?? tr.failed
      case .request: return tr.errNotFound
      default: return tr.errors("upstream") ?? tr.failed
      }
    case let e as StoreError: return "\(tr.failed): \(e.description)"
    case let e as TokenError: return "\(tr.failed): \(e.description)"
    case let e as BotSetupError: return "\(tr.failed): \(e.description)"
    case let e as SignError: return "\(tr.failed): \(e.description)"
    case let e as ShortcutMaker.MakeError: return "\(tr.failed): \(e.description)"
    case let e as Profile.ProfileError: return "\(tr.failed): \(e.description)"
    default: return tr.failed
    }
  }

  /// Run an action; report a failure as a toast and return nil (the setup page's `run`).
  @discardableResult
  public func run<R>(done: String? = nil, _ fn: () async throws -> R) async -> R? {
    do {
      let r = try await fn()
      if let done { toast(done) }
      return r
    } catch {
      toast(message(error), .error)
      return nil
    }
  }

  // MARK: settings

  public func setLanguages(siriLang: String? = nil, phoneLang: Lang? = nil, uiLang: Lang? = nil, appleSigning: Bool? = nil, announce: Bool = true) async {
    var p = SettingsPatch()
    if let siriLang, Langs.isSiriLang(siriLang) {
      p.siriLang = siriLang
      // The Shortcuts of the language left behind may be made again (Flow.languageSuggestion).
      if Langs.langOfSiri(siriLang) != Langs.langOfSiri(snapshot.siriLang) {
        prefs.siriLangBefore = snapshot.siriLang
        try? prefs.save(home)
      }
    }
    p.phoneLang = phoneLang?.rawValue
    p.uiLang = uiLang?.rawValue
    p.appleSigning = appleSigning
    if let uiLang { tr = loadTr(uiLang) }
    let ok = await run(done: announce ? tr.saved : nil) { try await host.config.putSettings(p) }
    if ok != nil { await refresh() }
  }

  /// "Not now" on the suggestion to make the old language's Shortcuts again: it goes away until
  /// the default language changes again.
  public func dismissLanguageSuggestion() {
    guard prefs.siriLangBefore != nil else { return }
    prefs.siriLangBefore = nil
    try? prefs.save(home)
    snapshot.siriLangBefore = nil
  }

  /// A first run starts with the Mac's language for Siri and for the iPhone steps; both can be
  /// changed in the Shortcut step and in Settings (the language step is gone, S16 D2).
  func firstRunLanguages() async {
    guard !prefs.languageSeen else { return }
    markLanguageSeen()
    guard snapshot.bots.isEmpty, snapshot.tokens.isEmpty else { return }
    let lang = env.uiLang ?? L10n.preferred()
    await setLanguages(siriLang: lang.info.siri, phoneLang: lang, announce: false)
    // A first run has no earlier language to suggest replacements for.
    dismissLanguageSuggestion()
  }

  public func markLanguageSeen() {
    guard !prefs.languageSeen else { return }
    prefs.languageSeen = true
    try? prefs.save(home)
  }

  public func setKeepAwake(_ on: Bool) async {
    prefs.keepAwake = on
    try? prefs.save(home)
    await host.setKeepAwake(on)
    await refresh()
  }

  public func setShowMenuBar(_ on: Bool) {
    // SwiftUI writes the menu bar item's binding back on updates: an unchanged value must not
    // touch `prefs`, or the scene updates again, forever.
    guard prefs.showMenuBar != on else { return }
    prefs.showMenuBar = on
    try? prefs.save(home)
  }

  /// Settings' footer: where Homebot goes when the window closes.
  public var windowNote: String { prefs.showMenuBar ? tr.windowNote : tr.windowNoteHidden }

  /// Opens the main window; set by the window when it first appears, so the app delegate can
  /// bring it back when Homebot is opened again with no window and no menu bar item.
  public var openMainWindow: (() -> Void)?

  /// Homebot opened again (Finder, Spotlight, the Dock) with no window shown.
  public func reopen() {
    host.log(["event": "app", "action": "reopen", "opener": .bool(openMainWindow != nil)])
    openMainWindow?()
    showInDock()
    NSApp?.activate()
  }

  public func setAppearance(_ a: Appearance) {
    prefs.appearance = a
    try? prefs.save(home)
    applyAppearance()
  }

  public func applyAppearance() {
    switch prefs.appearance {
    case .system: NSApp?.appearance = nil
    case .light: NSApp?.appearance = NSAppearance(named: .aqua)
    case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
    }
  }

  public func setAppIcon(_ icon: IconChoice) {
    prefs.icon = icon
    try? prefs.save(home)
    applyAppIcon()
  }

  /// Shows the chosen icon in the Dock and the app switcher; Automatic follows the app's
  /// appearance, and changes with it (`followAppearance`).
  public func applyAppIcon() {
    guard let app = NSApp else { return }
    let dark = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    app.applicationIconImage = IconRenderer.dockImage(prefs.icon.resolved(dark: dark))
    followAppearance()
  }

  /// Applies the icon again whenever the effective appearance changes (the system's, or the
  /// app's own setting). Set up once.
  private func followAppearance() {
    guard appearanceWatch == nil, let app = NSApp else { return }
    appearanceWatch = app.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
      Task { @MainActor in self?.applyAppIcon() }
    }
  }

  /// Gives the app its Dock tile again (the window opened). A new tile starts with the bundle
  /// icon, so the chosen one is applied again each time.
  public func showInDock() {
    NSApp?.setActivationPolicy(.regular)
    applyAppIcon()
  }

  public func setLoginItem(_ on: Bool) {
    do {
      try loginItems.set(on)
      loginItemError = nil
    } catch let e as LoginItemError {
      loginItemError = e
    } catch {
      loginItemError = .failed
    }
    loginItem = loginItems.state
  }

  public func openLoginItemsSettings() { loginItems.openSettings() }

  // MARK: import from the TypeScript version (§20.4, §20.11 B8)

  /// ~/.homebot of the user this app runs for (a dev run: its own temporary home folder).
  public var legacyFolder: URL { TSImport.defaultSource(userHome: env.userHome) }

  /// "~/.homebot", as the user would look for it.
  public var legacyFolderName: String {
    let home = env.userHome.standardizedFileURL.path
    let p = legacyFolder.standardizedFileURL.path
    return p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
  }

  public func lookForLegacy() {
    let p = try? TSImport.preview(legacyFolder)
    legacy = p?.moved == false ? p : nil
  }

  /// The import is offered while the old folder is there and this setup is still empty (the
  /// importer copies only into a new setup). Never started without the user's click.
  public var canImport: Bool { legacy != nil && snapshot.bots.isEmpty && snapshot.tokens.isEmpty }
  public var offersImport: Bool { canImport && !prefs.importDismissed }

  public func dismissImport() {
    prefs.importDismissed = true
    try? prefs.save(home)
  }

  /// Copy the old setup once. The gateway pauses meanwhile: the importer takes the new folder's
  /// owner lock and checks that nothing answers on the old version's ports (this app's own
  /// listener included), then the gateway starts again on the imported stores.
  @discardableResult
  public func importLegacy() async -> Bool {
    guard canImport, !importing else { return false }
    importing = true
    defer { importing = false }
    await host.stop()
    // A dev run never probes the user's own gateway ports: a fixture naming them counts as a
    // running old gateway (Codex S5 review).
    let dev = env.dev
    let probe: @Sendable (Int) -> Bool = { port in (dev && AppEnv.reservedPorts.contains(port)) || TSImport.listening(port) }
    let result: Result<TSImport.Report, Error>
    do {
      result = .success(try await TSImport.run(from: legacyFolder, to: home, keep: importKeep, isListening: probe))
    } catch {
      result = .failure(error)
    }
    await startGateway()
    lookForLegacy()
    await refresh()
    switch result {
    case .success(let r):
      importKeep = []
      page = Flow.startPage(snapshot)
      visit += 1
      // Done only when Siri can be answered with a key Grok Bot accepts (§20.4).
      if startFailed {
        toast(tr.importNoGateway, .error)
      } else {
        await checkKey()
        if snapshot.credential == nil { toast(tr["errors.no-credentials"], .error) }
        else if snapshot.credential?.access == .rejected { toast(tr["errors.auth"], .error) }
        else { toast(tr.fmt(tr.importDone, ["bots": "\(r.bots)", "shortcuts": "\(r.usable)"])) }
      }
      return true
    case .failure(let e as TSImport.ImportError) where e.oldGatewayRunning:
      toast(tr.importRunning, .error)
    case .failure(let e as TSImport.ImportError):
      toast(tr.fmt(tr.importFailed, ["reason": e.description]), .error)
    case .failure(let e):
      toast(message(e), .error)
    }
    return false
  }

  /// Settings' Import row: show the import card again (with its keep choices) instead of
  /// importing straight away.
  public func reviewImport() {
    prefs.importDismissed = false
    try? prefs.save(home)
  }

  // MARK: reset

  /// Settings' "Reset everything": the gateway stops, the support folder goes back to a first
  /// run (`Reset`), the gateway starts again and the app opens the Account step. The saved key
  /// goes only with `removeKey`. Shortcuts already installed stop working (unknown token).
  @discardableResult
  public func resetEverything(removeKey: Bool) async -> Bool {
    guard !resetting, !importing else { return false }
    resetting = true
    defer { resetting = false }
    removedKey = nil
    await host.stop()
    let result: Result<Reset.Report, Error>
    do {
      result = .success(try await Reset.run(home, removeKey: removeKey, userHome: env.userHome))
    } catch {
      result = .failure(error)
    }
    if case .success = result {
      await host.downloads.dropAll()
      await host.credentialStatus.reset()
      builds = [:]
      build = nil
      batch = []
      draft = nil
      renamedNotice = nil
      library = nil
      importKeep = []
      prefs = AppPrefs()
      if loginItem != .off { setLoginItem(false) }
      applyAppearance()
      applyAppIcon()
      tr = loadTr(env.uiLang ?? L10n.preferred())
      host.log(["event": "setup", "action": "reset", "key": .string(removeKey ? "removed" : "kept")])
    }
    await startGateway()
    lookForLegacy()
    await refresh()
    switch result {
    case .success:
      await firstRunLanguages()
      page = .account
      visit += 1
      if startFailed { toast(tr.gatewayFailed, .error) } else { toast(tr.resetDone) }
      return true
    case .failure(let e as Reset.ResetError):
      toast("\(tr.failed): \(e.description)", .error)
    case .failure(let e):
      toast(message(e), .error)
    }
    return false
  }

  // MARK: this Mac

  public func finishMacHints() {
    prefs.macHintsDone = true
    try? prefs.save(home)
  }

  /// Where the bundled CLI is, for agents (DESIGN §20.2).
  public var cliPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/homebot").path }

  // MARK: account

  public static func isPlausibleKey(_ k: String) -> Bool {
    k.range(of: #"^[\x21-\x7e]{8,512}$"#, options: .regularExpression) != nil
  }

  public func saveKey(_ raw: String) async -> Bool {
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let saved = await run { () -> Bool in
      guard AppModel.isPlausibleKey(key) else { throw AppError("key-invalid") }
      try host.credentials.save(key: key)
      host.log(["event": "setup", "action": "credential-saved"])
      return true
    }
    if saved == true { removedKey = nil }
    await refresh()
    if saved == true { await checkKey() }
    return saved == true
  }

  /// No toast: the step itself shows what is used now (the login, or the empty form). The key
  /// stays in memory for `undoRemoveKey`.
  public func removeKey() async {
    let old = try? host.credentials.savedKey()
    let removed = await run(done: nil) { () -> Bool in
      try host.credentials.removeSaved()
      host.log(["event": "setup", "action": "credential-removed"])
      return true
    }
    if removed == true, let old { removedKey = old }
    await refresh()
  }

  /// Saves the removed key again, unless another key was saved meanwhile (never replaced).
  @discardableResult
  public func undoRemoveKey() async -> Bool {
    guard let key = removedKey else { return false }
    let restored = await run { () -> Bool in
      guard try host.credentials.saveIfAbsent(key: key) else { return false }
      host.log(["event": "setup", "action": "credential-restored"])
      return true
    }
    removedKey = nil
    await refresh()
    if restored == true { await checkKey() }
    return restored == true
  }

  /// A read-only call with the key in use, when a bot exists to read (the CLI's account check):
  /// Home and the Account step then say whether Grok Bot accepted it.
  public func checkKey() async { await checkKey(onlyIfUnchecked: false) }

  func checkKey(onlyIfUnchecked: Bool) async {
    guard let b = snapshot.bots.first, let bdk = try? await client() else { return }
    let cursor = await host.state.cursor(b.key)?.cursor ?? "-1"
    do {
      _ = try await bdk.client.getEntries(sessionId: b.sessionId, afterUpdatedSeq: cursor)
      await recordAccess(true, bdk, onlyIfUnchecked: onlyIfUnchecked)
    } catch let e as BdkError where e.kind == .auth {
      await recordAccess(false, bdk, onlyIfUnchecked: onlyIfUnchecked)
    } catch {}
    await refresh()
  }

  /// `checkKey` when the key in use has no result in this run yet (launch; nothing to redo
  /// once a Siri request or an earlier check has answered it). Its result is kept only if no
  /// other result arrived while it was out.
  func checkKeyIfUnchecked() async {
    guard snapshot.credential?.access == .unchecked else { return }
    await checkKey(onlyIfUnchecked: true)
  }

  /// A client for the credential in use, with that credential's generation: a result is
  /// recorded against the key that was actually sent, never a key saved in the meantime.
  struct Bdk {
    let client: BdkClient
    let generation: Int
  }

  func recordAccess(_ ok: Bool, _ bdk: Bdk, onlyIfUnchecked: Bool = false) async {
    _ = await host.credentialStatus.record(generation: bdk.generation, accepted: ok, onlyIfUnchecked: onlyIfUnchecked)
  }

  func client() async throws -> Bdk {
    guard let c = try host.credentials.resolve() else { throw AppError("no-credentials") }
    let g = await host.credentialStatus.observe(c)
    if let t = env.transport { return Bdk(client: HTTPBdkClient(key: c.key, baseURL: env.bdkBaseURL, transport: t), generation: g) }
    return Bdk(client: HTTPBdkClient(key: c.key, baseURL: env.bdkBaseURL), generation: g)
  }

  // MARK: bots

  /// A bot key derived from the display name, unique among configured bots (setup.ts deriveKey).
  public static func deriveKey(_ name: String, sessionId: String, taken: Set<String>) -> String {
    var slug = name.lowercased().decomposedStringWithCompatibilityMapping
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    slug = String(slug.prefix(32))
    while slug.hasSuffix("-") { slug.removeLast() }
    let fallback = String("bot-\(sessionId)".prefix(32))
    for k in [slug, fallback] where !k.isEmpty && Bot.isValidKey(k) && !taken.contains(k) { return k }
    return fallback
  }

  static func cleanName(_ s: String) throws -> String {
    let n = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !n.isEmpty, n.count <= Bot.maxNameLength else { throw AppError("name") }
    return n
  }

  /// Cold-sync a session and install the bot through the lifecycle owner.
  func syncAndAdd(_ bot: Bot, _ bdk: Bdk) async throws {
    let r: ColdSync
    do {
      r = try await Bots.coldSync(bdk.client, sessionId: bot.sessionId)
    } catch let e as BdkError {
      if e.kind == .auth { await recordAccess(false, bdk) }
      host.log(["event": "setup", "action": "bot-add", "outcome": .string(e.kind.rawValue)])
      throw e
    }
    await recordAccess(true, bdk)
    do {
      try await host.lifecycle.add(bot, cursor: r.cursor, maxSeq: r.maxSeq)
    } catch {
      host.log(["event": "setup", "action": "bot-add", "outcome": "conflict"])
      throw AppError("taken")
    }
    host.log(["event": "setup", "action": "bot-add", "outcome": "ok"])
  }

  /// Add by exact name, typed twice (DECISIONS item 13). A name that matches no bot makes Grok
  /// Bot create an empty one; it is detected and never added.
  public func addByName(_ raw: String, confirm: String, strict: Bool) async -> Bool {
    let r = await run(done: tr.saved) { () -> Bool in
      let name = try AppModel.cleanName(raw)
      guard confirm.trimmingCharacters(in: .whitespacesAndNewlines) == name else { throw AppError("confirm-name") }
      let bdk = try await client()
      let found: (sessionId: String, justCreated: Bool)
      do {
        found = try await Bots.resolveByName(bdk.client, name: name)
      } catch let e as BdkError {
        if e.kind == .auth { await recordAccess(false, bdk) }
        throw e
      }
      await recordAccess(true, bdk)
      try await host.config.refresh()
      let bots = await host.config.bots()
      if found.justCreated {
        host.log(["event": "setup", "action": "bot-add-name", "outcome": "created-new"])
        if let same = bots.first(where: { $0.name.compare(name, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame }) {
          renamedNotice = RenamedBotNotice(key: same.key, name: same.name)
        }
        throw AppError("created-new")
      }
      if bots.contains(where: { $0.sessionId == found.sessionId }) { throw AppError("taken") }
      let key = AppModel.deriveKey(name, sessionId: found.sessionId, taken: Set(bots.map(\.key)))
      try await syncAndAdd(Bot(key: key, name: name, sessionId: found.sessionId, strictEcho: strict), bdk)
      return true
    }
    await refresh()
    return r == true
  }

  /// Advanced: add by numeric session id (read-only check).
  public func addBySession(_ rawId: String, name rawName: String, strict: Bool) async -> Bool {
    let r = await run(done: tr.saved) { () -> Bool in
      let sid = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !sid.isEmpty, sid.count <= 40, sid.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { throw AppError("session") }
      let name = try AppModel.cleanName(rawName)
      try await host.config.refresh()
      let bots = await host.config.bots()
      if bots.contains(where: { $0.sessionId == sid }) { throw AppError("taken") }
      let bot = Bot(key: AppModel.deriveKey(name, sessionId: sid, taken: Set(bots.map(\.key))), name: name, sessionId: sid, strictEcho: strict)
      do { try await host.config.checkBot(bot) } catch { throw AppError("taken") }
      try await syncAndAdd(bot, try await client())
      return true
    }
    await refresh()
    return r == true
  }

  /// "Create a bot" (§20.7): get-or-create with a new name, after the user confirmed. If a bot of
  /// that name already existed, it is added as it is.
  public func createBot(_ raw: String) async -> Bool {
    let r = await run { () -> Bool in
      let name = try AppModel.cleanName(raw)
      let bdk = try await client()
      let found: (sessionId: String, justCreated: Bool)
      do {
        found = try await Bots.resolveByName(bdk.client, name: name)
      } catch let e as BdkError {
        if e.kind == .auth { await recordAccess(false, bdk) }
        throw e
      }
      host.log(["event": "setup", "action": "bot-create", "outcome": .string(found.justCreated ? "created" : "existed")])
      try await host.config.refresh()
      let bots = await host.config.bots()
      if bots.contains(where: { $0.sessionId == found.sessionId }) { throw AppError("taken") }
      try await syncAndAdd(Bot(key: AppModel.deriveKey(name, sessionId: found.sessionId, taken: Set(bots.map(\.key))), name: name, sessionId: found.sessionId, strictEcho: true), bdk)
      return found.justCreated
    }
    await refresh()
    if let created = r { toast(created ? tr.saved : tr.botExisted, created ? .success : .info) }
    return r != nil
  }

  public func renameBot(_ key: String, to name: String) async -> Bool {
    let r = await run(done: tr.saved) { () -> Bool in
      let n = try AppModel.cleanName(name)
      guard try await host.lifecycle.rename(key, to: n) else { throw AppError("not-found") }
      host.log(["event": "setup", "action": "bot-rename"])
      return true
    }
    await refresh()
    return r == true
  }

  /// Strict checking back on for a bot added without it: no need to remove the bot (which would
  /// retire its Shortcuts) to undo that choice.
  public func setStrict(_ key: String, _ on: Bool) async {
    await run(done: tr.saved) {
      guard try await host.lifecycle.setStrict(key, on) else { throw AppError("not-found") }
      host.log(["event": "setup", "action": "bot-strict", "on": .bool(on)])
    }
    await refresh()
  }

  public func removeBot(_ key: String) async {
    await run(done: tr.saved) {
      guard let r = try await host.lifecycle.remove(key) else { throw AppError("not-found") }
      for id in r.retired {
        await host.downloads.dropToken(id)
        builds[id] = nil
      }
      host.log(["event": "setup", "action": "bot-remove"])
    }
    await refresh()
  }

  // MARK: Shortcuts

  public func revoke(_ id: String) async {
    await run(done: tr.saved) {
      guard try await host.tokens.revoke(id) else { throw AppError("not-found") }
      await host.downloads.dropToken(id)
      builds[id] = nil
      host.log(["event": "setup", "action": "token-revoke"])
    }
    await refresh()
  }

  /// The bots a Shortcut is for (one, or the entry Shortcut's set in menu order), its profile,
  /// the gateway URL and its host:port.
  func profile(_ input: ShortcutInput) async throws -> ([Bot], ShortcutProfile, String, String) {
    try await host.config.refresh()
    try await host.tokens.refresh()
    var bots: [Bot] = []
    for k in input.entry ? input.bots : [input.bot] {
      guard let b = await host.config.bot(k) else { throw AppError("not-found") }
      bots.append(b)
    }
    guard let bot = bots.first else { throw AppError("entry-none") }
    let s = await host.config.settings
    let list = await host.tokens.list()
    let replaces = input.replaces.flatMap { $0.isEmpty ? nil : $0 }
    let phrase = input.name.flatMap(ShortcutInput.phrase)
    let siriLang = input.siriLang.flatMap { Langs.isSiriLang($0) ? $0 : nil } ?? s.siriLang ?? Langs.defaultSiriLang
    let phoneLang = s.phoneLang ?? Langs.defaultPhoneLang.rawValue
    let keep = Profile.keptPhrase(replaces.flatMap { r in list.first { $0.id == r } }, siriLang: siriLang)
    let chain = TokenStore.takeoverChain(from: replaces) { r in list.first { $0.id == r && $0.state == .pending && $0.usedAt == nil }?.replaces }
    // A copy for another Apple Account (or a replacement of one) may share any phrase; copies for
    // another account never take one from this account (S26).
    let other = input.otherAccount || replaces.flatMap { r in list.first { $0.id == r }?.otherAccount } == true
    let taken = other ? [] : Profile.takenPhrases(list.filter { $0.otherAccount != true }.map { ($0.id, $0.label, $0.state) }, replaces: replaces, chain: chain)
    let p = input.entry
      ? try Profile.entry(siriLang: siriLang, phoneLang: phoneLang, name: phrase, keep: keep, taken: taken)
      : try Profile.make(botName: bot.name, siriLang: siriLang, phoneLang: phoneLang, name: phrase, keep: keep, taken: taken)
    let baseUrl = input.url.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) } ?? snapshot.gatewayURL
    guard let c = URLComponents(string: baseUrl), let scheme = c.scheme, scheme == "http" || scheme == "https", let h = c.host, !h.isEmpty else { throw AppError("gateway-url") }
    return (bots, p, baseUrl, c.port.map { "\(h):\($0)" } ?? h)
  }

  public func preview(_ input: ShortcutInput) async throws -> ShortcutPreview {
    let (bots, p, _, _) = try await profile(input)
    let name = ShortcutMaker.safeFileName(p.name)
    let problems = p.problems.map { x in
      PhraseProblemView(code: x.code.rawValue, text: tr.problems(x.blocking ? x.code.rawValue : "\(x.code.rawValue)-advice") ?? x.message, blocking: x.blocking)
    }
    let say = Langs.heySiri(p.siriLang, name)
    var r = ShortcutPreview(name: name, prompt: p.prompt, siriLang: p.siriLang, say: say, alternatives: p.alternatives, problems: problems)
    if input.entry {
      let items = bots.map(EntryChoice.init)
      r.exchange = EntryPreview.lines(phrase: name, bots: items, siriLang: p.siriLang)
      r.numberOnly = Chooser.ambiguousNames(items, p.replyLang)
    } else {
      r.exchange = [EntryPreview.Line(user: true, text: say), EntryPreview.Line(user: false, text: p.prompt)]
    }
    return r
  }

  /// The consent to send Shortcuts to Apple for signing (DECISIONS item 24): given once by clicking
  /// a button that says "Sign with Apple and make"; only Reset everything clears it (signing is
  /// required, so there is no switch to withdraw it, S21). Stored as `settings.appleSigning`,
  /// shared with the CLI. Returns whether consent is now given.
  @discardableResult
  public func giveSigningConsent() async -> Bool {
    if !snapshot.appleSigning {
      await setLanguages(appleSigning: true, announce: false)
      host.log(["event": "setup", "action": "signing-consent", "on": .bool(true)])
    }
    return snapshot.appleSigning
  }

  // MARK: usage counts, update check, email

  static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }

  func usageTick() async {
    try? await host.config.refresh()
    let settings = await host.config.settings
    let activity = host.activity
    await usage.tick(settings: settings, app: Self.appVersion, lang: tr.lang) {
      Usage.answered((try? await activity.recent(limit: Usage.recentLimit)) ?? [], now: Date())
    }
    update = settings.updateCheck == false ? nil : await usage.update(current: Self.appVersion)
  }

  public func setUsageCounts(_ on: Bool) async {
    var p = SettingsPatch()
    p.usageCounts = on
    if await run(done: nil, { try await host.config.putSettings(p) }) != nil {
      await refresh()
      if on { await usageTick() }
    }
  }

  public func setUpdateCheck(_ on: Bool) async {
    var p = SettingsPatch()
    p.updateCheck = on
    if await run(done: nil, { try await host.config.putSettings(p) }) != nil {
      await refresh()
      await usageTick()
    }
  }

  /// Help › Stay in touch. True when homebot.fun took the sign-up (it answers the same for any
  /// address, so this never says whether an address is already on the list).
  public func subscribe(email: String) async -> Bool {
    await usage.subscribe(email: email.trimmingCharacters(in: .whitespacesAndNewlines), lang: tr.lang)
  }

  /// The Shortcut step's button: the click is the consent when none is stored yet, and the
  /// Shortcut is always signed. Nothing is built if the consent can't be stored.
  public func signAndMake(_ input: ShortcutInput) async -> ShortcutBuild? {
    guard await giveSigningConsent() else { return nil }
    return await makeShortcut(input, sign: true)
  }

  public func makeShortcut(_ input: ShortcutInput, sign: Bool) async -> ShortcutBuild? {
    let r = await run { () -> ShortcutBuild in
      let (bots, p, baseUrl, hostPort) = try await profile(input)
      if sign {
        try await host.config.refresh()
        guard await host.config.settings.appleSigning == true else { throw AppError("signing-consent") }
      }
      let log = host.log
      let config = host.config
      let send: SignFn = env.sign ?? { (i: String, o: String) async throws -> Void in
        _ = try await Signer.sign(input: i, output: o, onAttempt: { n, mode in log(["event": "setup", "action": "sign-attempt", "attempt": .int(n), "mode": .string(mode.rawValue)]) })
      }
      // Checked again right before anything goes to Apple: a reset meanwhile (here or by the CLI) wins.
      var signer: SignFn?
      if sign {
        signer = { (i: String, o: String) async throws -> Void in
          try await config.refresh()
          guard await config.settings.appleSigning == true else { throw AppError("signing-consent") }
          try await send(i, o)
        }
      }
      let replaces = input.replaces.flatMap { $0.isEmpty ? nil : $0 }
      let made: MadeShortcut
      do {
        made = try await ShortcutMaker.make(tokens: host.tokens, lifecycle: host.lifecycle, bots: bots, profile: p, baseUrl: baseUrl, kind: input.entry ? .entry : input.conversation ? .conversation : .ask, replaces: replaces, otherAccount: input.otherAccount, sign: signer)
      } catch {
        log(["event": "setup", "action": "shortcut-build", "outcome": "error"])
        throw error
      }
      builds[made.tokenId] = (made.file, made.name, baseUrl, made.signed)
      // Built for this Mac's own address: if that changes, the Shortcut needs making again.
      if baseUrl == snapshot.gatewayURL {
        prefs.builtFor[made.tokenId] = hostPort
        try? prefs.save(home)
      }
      log(["event": "setup", "action": "shortcut-build", "outcome": "ok", "signed": .bool(made.signed)])
      return ShortcutBuild(tokenId: made.tokenId, name: made.name, signed: made.signed, steps: p.steps(host: hostPort, name: made.name), host: hostPort, say: Langs.heySiri(p.siriLang, made.name), prompt: p.prompt,
                          endWord: input.conversation && !input.entry ? Conversation.endWord(Langs.replyLang(p.siriLang)) : nil)
    }
    if let r {
      build = r
      batch = []
    }
    await refresh()
    return r
  }

  /// Makes new-language versions of the Shortcuts made for another Siri language
  /// (`Flow.languageSuggestion`, or the given ones of them): the same bots and kind, the default
  /// phrase of the new language (never one already in use) and the user's signing choice. They
  /// are extra Shortcuts: the old ones keep working in their language (DESIGN §7.3, S15 D4).
  /// Stops at the first failure, which is shown.
  /// `consent`: the user clicked a button that says it signs with Apple.
  @discardableResult
  public func makeReplacements(_ ids: [String]? = nil, consent: Bool = false) async -> [ShortcutBuild] {
    guard !replacing else { return [] }
    if consent, !(await giveSigningConsent()) { return [] }
    replacing = true
    defer { replacing = false }
    // All in one Siri language: stop if it changes between builds.
    let lang = snapshot.siriLang
    var made: [ShortcutBuild] = []
    for t in Flow.languageSuggestion(snapshot) where ids?.contains(t.id) ?? true {
      guard snapshot.siriLang == lang else { break }
      // An extra Shortcut, replacing nothing: the old one keeps working in its language.
      let input = t.mode == .entry
        ? ShortcutInput(bot: t.bot, replaces: "", entry: true, bots: t.bots)
        : ShortcutInput(bot: t.bot, replaces: "", conversation: t.mode == .conversation)
      guard let b = await makeShortcut(input, sign: snapshot.appleSigning) else { break }
      made.append(b)
    }
    if let first = made.first { build = first }
    batch = made
    return made
  }

  /// T4: the bots an entry Shortcut answers for, in menu order. No new Shortcut is needed.
  @discardableResult
  public func setTokenBots(_ id: String, _ keys: [String]) async -> Bool {
    let r = await run(done: tr.saved) { () -> Bool in
      guard !keys.isEmpty else { throw AppError("entry-none") }
      try await host.config.refresh()
      var bots: [Bot] = []
      for k in keys {
        guard let b = await host.config.bot(k) else { throw AppError("not-found") }
        bots.append(b)
      }
      try await host.lifecycle.setBots(id, bots)
      host.log(["event": "setup", "action": "token-bots"])
      return true
    }
    await refresh()
    return r == true
  }

  func builtFile(_ tokenId: String) throws -> (file: URL, name: String, baseUrl: String, signed: Bool) {
    if let b = builds[tokenId] {
      guard FileManager.default.fileExists(atPath: b.file.path) else { throw AppError("gone") }
      return b
    }
    // Made in an earlier run and not used yet: its file is still in the token's folder (24 h).
    guard let t = snapshot.tokens.first(where: { $0.id == tokenId }), t.state == .pending, t.usedAt == nil, let f = diskFile(tokenId) else { throw AppError("gone") }
    let base = prefs.builtFor[tokenId].map { "http://\($0)" } ?? snapshot.gatewayURL
    return (f.file, f.name, base, f.signed)
  }

  /// The Shortcut file left in a token's folder: the signed one if there is one.
  func diskFile(_ tokenId: String) -> (file: URL, name: String, signed: Bool)? {
    guard let dir = try? host.tokens.artifactDir(tokenId),
          let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
    let all = files.filter { $0.pathExtension == "shortcut" }
    let unsignedExt = ".unsigned.shortcut"
    if let f = all.first(where: { !$0.lastPathComponent.hasSuffix(unsignedExt) }) {
      return (f, String(f.lastPathComponent.dropLast(".shortcut".count)), ShortcutFile.isSigned(f))
    }
    if let f = all.first(where: { $0.lastPathComponent.hasSuffix(unsignedExt) }) {
      return (f, String(f.lastPathComponent.dropLast(unsignedExt.count)), false)
    }
    return nil
  }

  // MARK: install (S16)

  public func setInstallTarget(_ t: InstallTarget) {
    guard prefs.installTarget != t else { return }
    prefs.installTarget = t
    try? prefs.save(home)
    libraryAt = .distantPast
    Task { await readLibrary() }
  }

  /// The Install page for a Shortcut of the list: its file if it is still here, else the page
  /// offers a new copy.
  /// One that can no longer reach Homebot (`Flow.needsUpdate`) gets a new copy first: its file
  /// still holds the old address.
  public func install(_ t: TokenView) async {
    // Nothing is built for a step that is not open: go lands on the first step not done.
    guard Flow.canOpen(.install, snapshot) else { return go(.install) }
    if Flow.needsUpdate(t, snapshot) {
      guard await makeCopy(t.id) != nil else { return }
    } else if build?.tokenId != t.id {
      build = await buildView(t)
    }
    batch = []
    go(.install)
  }

  /// What the Install page needs to show a Shortcut made earlier (in this run or before).
  func buildView(_ t: TokenView) async -> ShortcutBuild {
    let input = ShortcutInput(bot: t.bot, name: t.label, replaces: t.id, entry: t.mode == .entry, bots: t.bots, siriLang: t.siriLang, conversation: t.mode == .conversation)
    let file = try? builtFile(t.id)
    var b = ShortcutBuild(tokenId: t.id, name: t.label, signed: file?.signed ?? false, steps: [])
    if let (_, p, _, hostPort) = try? await profile(input) {
      b.steps = p.steps(host: prefs.builtFor[t.id] ?? hostPort, name: t.label)
      b.host = prefs.builtFor[t.id] ?? hostPort
      b.say = Langs.heySiri(p.siriLang, t.label)
      b.prompt = p.prompt
      b.endWord = t.mode == .conversation ? Conversation.endWord(Langs.replyLang(p.siriLang)) : nil
    } else {
      b.say = Langs.heySiri(t.siriLang, t.label)
    }
    return b
  }

  /// A new copy of a Shortcut whose file is gone: the same phrase, bots, language and kind. It
  /// replaces this one once it has answered (a never-used one is replaced at once).
  /// `replacing: false` is a copy for another device (S26): the file is gone once a Shortcut is in
  /// use and its token is kept only as a hash, so another iPhone needs a token of its own. It
  /// replaces nothing, so the device already using this one keeps working, and it takes the first
  /// free phrase, since two Shortcuts can't share one (§16.2). With `otherAccount` (an iPhone on
  /// another Apple Account, whose Siri never sees this account's Shortcuts) it keeps the phrase.
  /// `consent`: the user clicked a button that says it signs with Apple.
  @discardableResult
  public func makeCopy(_ tokenId: String, consent: Bool = false, replacing: Bool = true, otherAccount: Bool = false) async -> ShortcutBuild? {
    guard let t = snapshot.tokens.first(where: { $0.id == tokenId }), t.state != .retired else { return nil }
    if consent, !(await giveSigningConsent()) { return nil }
    let other = !replacing && otherAccount
    let input = ShortcutInput(bot: t.bot, name: replacing || other ? t.label : nil, replaces: replacing ? t.id : nil, entry: t.mode == .entry, bots: t.bots, siriLang: t.siriLang, conversation: t.mode == .conversation, otherAccount: other)
    return await makeShortcut(input, sign: snapshot.appleSigning)
  }

  /// Opens the Shortcut's file in the Shortcuts app on this Mac, which shows its "Add Shortcut"
  /// window. With iCloud Sync on (same Apple Account), Shortcuts brings it to the iPhone.
  /// The library is read first: over a Shortcut of the same name, adding can leave only renamed
  /// copies, so the page asks to remove the old one instead (`MacAddState.nameTaken`).
  public func addOnMac(_ tokenId: String) async {
    if !prefs.addedOnMac.contains(tokenId), let b = try? builtFile(tokenId), let names = await env.library() {
      library = names
      libraryAt = Date()
      if ShortcutsLibrary.has(names, b.name) { return }
    }
    await run {
      let b = try builtFile(tokenId)
      if !prefs.addedOnMac.contains(tokenId) {
        prefs.addedOnMac.append(tokenId)
        // Only Shortcuts still in the list are kept.
        let live = Set(snapshot.tokens.filter { $0.state != .retired }.map(\.id))
        prefs.addedOnMac.removeAll { !live.contains($0) && $0 != tokenId }
        try? prefs.save(home)
      }
      let app = URL(fileURLWithPath: "/System/Applications/Shortcuts.app")
      let config = NSWorkspace.OpenConfiguration()
      config.activates = true
      _ = try await NSWorkspace.shared.open([b.file], withApplicationAt: app, configuration: config)
      host.log(["event": "setup", "action": "add-on-mac"])
    }
    libraryAt = .distantPast
  }

  /// Shows a Shortcut by name in the Shortcuts app (Apple's `shortcuts://open-shortcut`).
  public func showInShortcuts(_ name: String) {
    if let u = ShortcutsURL.open(name) { NSWorkspace.shared.open(u) }
  }

  /// Opens the Shortcuts app on its library (All Shortcuts), where a Shortcut is deleted: Apple
  /// offers no URL for the library or for deleting, and `shortcuts` has no delete (S26).
  public func openShortcuts() {
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Shortcuts.app"), configuration: config)
  }

  /// Runs a Shortcut by name in the Shortcuts app (Apple's `shortcuts://run-shortcut`): on the Mac
  /// it asks to connect, then for the question.
  public func tryOnMac(_ name: String) {
    if let u = ShortcutsURL.run(name) { NSWorkspace.shared.open(u) }
    host.log(["event": "setup", "action": "try-on-mac"])
  }

  public func reveal(_ tokenId: String) async {
    await run {
      let b = try builtFile(tokenId)
      NSWorkspace.shared.activateFileViewerSelecting([b.file])
    }
  }

  /// A one-time download link for the phone (one use, ten minutes, on the voice listener).
  public func link(_ tokenId: String) async -> DownloadLink? {
    await run { () -> DownloadLink in
      let b = try builtFile(tokenId)
      guard var origin = URLComponents(string: b.baseUrl) else { throw AppError("gateway-url") }
      origin.path = ""
      origin.query = nil
      origin.fragment = nil
      let made = await host.downloads.create(file: b.file, name: b.name, tokenId: tokenId)
      host.log(["event": "setup", "action": "link-created"])
      return DownloadLink(url: "\(origin.string ?? b.baseUrl)/dl/\(made.id)", expiresAt: made.expiresAt)
    }
  }

  // MARK: activity

  public func clearActivity() async {
    await run(done: tr.cleared) {
      try await host.activity.clear()
      host.log(["event": "activity-cleared"])
    }
    activity = []
    await refresh()
  }

  // MARK: navigation

  /// Opens `p`, or the first step not done when `p` is a step that is not open yet
  /// (`Flow.landing`).
  public func go(_ to: Page) {
    let p = Flow.landing(to, snapshot)
    if p != .shortcut { draft = nil }
    page = p
    visit += 1
  }

  /// Where Make Shortcut goes: the Shortcut step when it is open, else the first step not done.
  public var makeShortcutPage: Page { Flow.landing(.shortcut, snapshot) }

  public var setUp: Bool { Flow.isSetUp(snapshot) }
  public var asksUsage: Bool { Flow.asksUsage(snapshot, running: status?.running == true, forcedOff: usage.forcedOff) }
  public var progress: [Page: StepState] { Flow.progress(snapshot) }
}
