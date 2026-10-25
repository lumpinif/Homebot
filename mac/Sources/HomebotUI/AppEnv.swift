// How this launch of Homebot.app is set up. A normal launch uses the real support folder
// (~/Library/Application Support/Homebot), the stored port, Cursor's API and Apple's signing
// service. Dev mode (`--dev`, for verification only) uses a throwaway folder, 127.0.0.1:18787,
// a Grok Bot API on loopback (the fake one, scripts/fake-grokbot.ts) and a fake signer, and never
// registers a login item, so a dev run can't touch a real account, Apple's service or the
// user's own Homebot. Launch arguments only: like the CLI, the app reads no environment
// variables (DESIGN §20.4).
import Foundation
import HomebotCore
import HomebotGateway

public struct AppEnv: Sendable {
  public var dev = false
  /// The support folder; nil: ~/Library/Application Support/Homebot.
  public var home: URL?
  /// The user's home directory, where the BDK login is looked for.
  public var userHome = FileManager.default.homeDirectoryForCurrentUser
  public var port: Int?
  public var bind: String?
  public var bdkBaseURL = HTTPBdkClient.defaultBaseURL
  /// nil: Apple's signing service through `shortcuts sign` (only with the user's consent).
  public var sign: SignFn?
  /// Dev runs keep the login item in memory instead of registering the app with macOS.
  public var fakeLoginItem = false
  /// Tests: an in-process Grok Bot API (never set by launch arguments).
  public var transport: HTTPTransport?
  /// Tests: where usage pings, the update check and email sign-ups go. Dev runs and runs with
  /// another Homebot folder reach no server unless this is set.
  public var usageTransport: HTTPTransport?

  // Dev only: where the window opens and how, for screenshots and smoke runs.
  public var page: String?
  public var uiLang: Lang?
  public var appearance: Appearance?
  /// `--dev-app-icon glow|black|white`: start with this app icon chosen.
  public var appIcon: IconChoice?
  /// `--dev-scroll-bottom`: open the page scrolled to its end (screenshots of long pages).
  public var scrollBottom = false
  public var seed: DevSeed.Level = .none
  /// `--dev-legacy`: put a TypeScript Homebot folder (fake bots, a test key) in the dev home folder,
  /// so the import offer can be tried (DevSeed.writeLegacyFolder).
  public var legacy = false
  /// `--dev-click-import`: once the window is up, import as if Import had been clicked (dev
  /// screenshots and smoke runs of the import, which background automation can't click).
  public var clickImport = false
  /// `--dev-placement translocated|elsewhere`: act as if the app ran from there (the
  /// "move to Applications" hints). nil: where the bundle really is; dev runs count as Applications.
  public var placement: AppPlacement?
  /// `--render-icon <dir>`: draw each app icon's PNGs into dir/<resource>.iconset and exit
  /// (scripts/build-app.sh).
  public var renderIcon: URL?
  /// `--print-placement`: print where this copy runs from (applications, translocated, elsewhere)
  /// and exit; scripts/release.sh checks the downloaded-copy cases with it.
  public var printPlacement = false
  /// The Shortcuts library on this Mac (`shortcuts list`); tests and `--dev-library` replace it.
  public var library: @Sendable () async -> [String]? = { await ShortcutsLibrary.list() }
  /// `--dev-install mac|iphone`: start with this answer to "same Apple Account?" (screenshots).
  public var installTarget: InstallTarget?

  public init() {}

  /// A Grok Bot API address that refuses every connection: what a dev run uses when no fake was
  /// given, so it can never reach Cursor's API.
  public static let deadEnd = "http://127.0.0.1:9/v0/grokbot/sessions"
  public static let devPort = 18787

  public struct UsageError: Error, CustomStringConvertible {
    public let description: String
  }

  public static func parse(_ args: [String]) throws -> AppEnv {
    var e = AppEnv()
    var i = 0
    var devHome: URL?
    var devLogin = false
    var devLibrary = false
    var base: String?
    func value(_ name: String) throws -> String {
      i += 1
      guard i < args.count else { throw UsageError(description: "\(name) needs a value") }
      return args[i]
    }
    while i < args.count {
      let a = args[i]
      switch a {
      case "--dev": e.dev = true
      case "--dev-home": devHome = URL(fileURLWithPath: (try value(a) as NSString).expandingTildeInPath, isDirectory: true)
      case "--dev-bdk-login": devLogin = true
      case "--bdk-base-url": base = try value(a)
      case "--dev-page": e.page = try value(a)
      case "--dev-scroll-bottom": e.scrollBottom = true
      case "--dev-lang":
        let v = try value(a)
        guard let l = Lang(rawValue: v) else { throw UsageError(description: "unknown language \(v)") }
        e.uiLang = l
      case "--dev-appearance":
        let v = try value(a)
        guard let ap = Appearance(rawValue: v) else { throw UsageError(description: "appearance is system, light or dark") }
        e.appearance = ap
      case "--dev-app-icon":
        let v = try value(a)
        guard let i = IconChoice(rawValue: v) else { throw UsageError(description: "app icon is automatic, glow, black or white") }
        e.appIcon = i
      case "--dev-seed":
        let v = try value(a)
        guard let s = DevSeed.Level(rawValue: v) else { throw UsageError(description: "seed is none, key, bot, shortcut, activity or entry") }
        e.seed = s
      case "--dev-legacy": e.legacy = true
      case "--dev-click-import": e.clickImport = true
      case "--dev-placement":
        let v = try value(a)
        guard let pl = AppPlacement(rawValue: v) else { throw UsageError(description: "placement is applications, translocated or elsewhere") }
        e.placement = pl
      case "--dev-library":
        // "a|b|c": the names the Shortcuts library shows (screenshots of the This Mac path).
        let names = (try value(a)).split(separator: "|").map(String.init)
        e.library = { names }
        devLibrary = true
      case "--dev-install":
        let v = try value(a)
        guard let t = InstallTarget(rawValue: v) else { throw UsageError(description: "install target is mac or iphone") }
        e.installTarget = t
      case "--print-placement": e.printPlacement = true
      case "--render-icon": e.renderIcon = URL(fileURLWithPath: try value(a), isDirectory: true)
      default:
        // macOS and Xcode add their own arguments (-NSDocumentRevisionsDebugMode YES, -psn_…).
        if a.hasPrefix("-NS") || a.hasPrefix("-Apple") { i += 1 }
      }
      i += 1
    }
    let devOnly = devHome != nil || devLogin || base != nil || e.page != nil || e.uiLang != nil || e.appearance != nil || e.appIcon != nil || e.scrollBottom || e.seed != .none || e.legacy || e.clickImport || e.placement != nil || devLibrary || e.installTarget != nil
    if devOnly && !e.dev { throw UsageError(description: "--dev-… options and --bdk-base-url need --dev") }
    guard e.dev else { return e }

    let root = devHome ?? FileManager.default.temporaryDirectory.appendingPathComponent("homebot-dev-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try checkDevRoot(root)
    e.home = root.appendingPathComponent("support", isDirectory: true)
    e.userHome = root.appendingPathComponent("user", isDirectory: true)
    try FileManager.default.createDirectory(at: e.userHome, withIntermediateDirectories: true)
    e.port = devPort
    e.bind = "127.0.0.1"
    e.bdkBaseURL = base ?? deadEnd
    guard GatewayOptions.isAllowedBase(e.bdkBaseURL), e.bdkBaseURL != HTTPBdkClient.defaultBaseURL,
          let port = URLComponents(string: e.bdkBaseURL)?.port, !reservedPorts.contains(port) else {
      throw UsageError(description: "in dev mode --bdk-base-url must be a loopback http URL with its own port (the fake Grok Bot)")
    }
    // Never Apple's signing service in dev mode: "Sign with Apple" copies the file unsigned.
    e.sign = { input, output in
      try? FileManager.default.removeItem(atPath: output)
      try FileManager.default.copyItem(atPath: input, toPath: output)
    }
    e.fakeLoginItem = true
    if devLogin { try DevSeed.writeFakeLogin(userHome: e.userHome) }
    if e.legacy { try DevSeed.writeLegacyFolder(userHome: e.userHome) }
    if e.placement == nil { e.placement = .applications }
    return e
  }
}

extension AppEnv {
  /// Ports a dev run never sends to: the user's own TypeScript gateway and setup page, and the
  /// dev gateway itself.
  static let reservedPorts: Set<Int> = [8787, 8788, devPort]

  /// A dev folder must not be, contain, or sit inside a real Homebot folder, and its `support`,
  /// `user` and `user/.homebot` folders must not be links that lead elsewhere (the dev legacy
  /// fixture is written into the last one).
  static func checkDevRoot(_ root: URL, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
    func real(_ u: URL) -> String { u.standardizedFileURL.resolvingSymlinksInPath().path }
    let r = real(root)
    let protected = [
      userHome.appendingPathComponent(".homebot"),
      userHome.appendingPathComponent("Library/Application Support/Homebot"),
    ].map(real)
    for p in protected where r == p || r.hasPrefix(p + "/") || p.hasPrefix(r + "/") {
      throw UsageError(description: "--dev-home must not be a real Homebot folder or contain one")
    }
    for sub in ["support", "user", "user/.homebot"] {
      let u = root.appendingPathComponent(sub)
      if (try? FileManager.default.destinationOfSymbolicLink(atPath: u.path)) != nil {
        throw UsageError(description: "--dev-home/\(sub) must not be a link")
      }
    }
  }
}

public enum Appearance: String, Sendable, CaseIterable, Codable {
  case system, light, dark
}
