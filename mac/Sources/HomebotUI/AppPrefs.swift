// The app's own preferences, in `app.json` next to the other stores (0600, atomic writes). Kept in
// the support folder rather than UserDefaults so a dev run's folder holds all of its state and
// never mixes with the user's own Homebot. Languages and signing consent stay in config.json,
// shared with the CLI.
import Foundation
import HomebotCore

public struct AppPrefs: Codable, Sendable, Equatable {
  /// "Keep this Mac awake for Siri" (DESIGN §20.3); on by default.
  public var keepAwake = true
  public var appearance: Appearance = .system
  /// The icon the running app shows; Automatic (White in Light, Black in Dark) by default.
  public var icon: IconChoice = .automatic
  /// The language step was looked at (it has nothing to save, so it counts as done once seen).
  public var languageSeen = false
  /// "Not now" on the offer to import the earlier Homebot (Settings still offers it).
  public var importDismissed = false
  /// Home's "Make this Mac ready for Siri" card was closed.
  public var macHintsDone = false
  /// The default language the user last switched away from: its Shortcuts are suggested to be
  /// made again (`Flow.languageSuggestion`) until the suggestion is dismissed.
  public var siriLangBefore: String?
  /// The gateway address ("host:port") each Shortcut's file was built with, when Homebot built it
  /// for its own address (`Flow.needsUpdate`).
  public var builtFor: [String: String] = [:]
  /// Where Shortcuts are installed: this Mac (iCloud brings them to the iPhone) or the iPhone;
  /// nil until the user answers (S16).
  public var installTarget: InstallTarget?
  /// Shortcuts the user sent to the Shortcuts app on this Mac ("Add to Shortcuts"), by token id.
  public var addedOnMac: [String] = []
  /// The menu bar item; on by default. Off, the gateway still runs and opening Homebot again
  /// (Applications, Spotlight, the Dock) brings the window back.
  public var showMenuBar = true

  public init() {}

  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? true
    appearance = (try? c.decodeIfPresent(Appearance.self, forKey: .appearance)) ?? .system
    // Before Automatic (S10) the choice was "appIcon", always written, Glow by default: Glow
    // there means never picked, so it becomes Automatic; Black and White were picked.
    if let i = try? c.decodeIfPresent(IconChoice.self, forKey: .icon) {
      icon = i
    } else {
      let old = try? d.container(keyedBy: Legacy.self).decodeIfPresent(AppIcon.self, forKey: .appIcon)
      icon = old == .black ? .black : old == .white ? .white : .automatic
    }
    languageSeen = try c.decodeIfPresent(Bool.self, forKey: .languageSeen) ?? false
    importDismissed = try c.decodeIfPresent(Bool.self, forKey: .importDismissed) ?? false
    macHintsDone = try c.decodeIfPresent(Bool.self, forKey: .macHintsDone) ?? false
    siriLangBefore = try? c.decodeIfPresent(String.self, forKey: .siriLangBefore)
    builtFor = (try? c.decodeIfPresent([String: String].self, forKey: .builtFor)) ?? [:]
    installTarget = try? c.decodeIfPresent(InstallTarget.self, forKey: .installTarget)
    addedOnMac = (try? c.decodeIfPresent([String].self, forKey: .addedOnMac)) ?? []
    showMenuBar = (try? c.decodeIfPresent(Bool.self, forKey: .showMenuBar)) ?? true
  }

  enum Legacy: String, CodingKey { case appIcon }

  public static func file(_ home: Home) -> URL { home.root.appendingPathComponent("app.json") }

  public static func load(_ home: Home) -> AppPrefs {
    (try? FileUtil.readJSON(AppPrefs.self, from: file(home))) ?? AppPrefs()
  }

  public func save(_ home: Home) throws {
    try FileUtil.writeJSON(AppPrefs.file(home), self)
  }
}
