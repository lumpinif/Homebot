// UI text in the page language (DECISIONS item 22): one String Catalog, mac/App/Localizable.xcstrings,
// generated from the setup page's catalogs plus the app's own text and compiled into
// <lang>.lproj/Localizable.strings by scripts/build-app.sh. The page language is the user's
// choice in the app, not the system's, so each table is read directly instead of through
// Bundle's preferred localization. Spoken text is not here: it follows the Siri language and
// lives in HomebotCore's catalogs.
import Foundation
import HomebotCore

public struct Tr: Sendable {
  public let lang: Lang
  let table: [String: String]
  let fallback: [String: String]

  public init(lang: Lang, table: [String: String], fallback: [String: String] = [:]) {
    self.lang = lang
    self.table = table
    self.fallback = fallback
  }

  /// The text for `key`; English if this language lacks it, the key itself if both do.
  public subscript(_ key: String) -> String { table[key] ?? fallback[key] ?? key }

  public func lookup(_ key: String) -> String? { table[key] ?? fallback[key] }

  /// Fill {placeholders}, as the setup page's `fmt` does.
  public func fmt(_ s: String, _ vars: [String: String]) -> String {
    var out = s
    for (k, v) in vars { out = out.replacingOccurrences(of: "{\(k)}", with: v) }
    return out
  }

  /// A UI label for an activity outcome code (A2); `not-sent:<why>` and `no-reply:<why>` use the
  /// base code, unknown codes show as "other". The Shortcut stopping (`:disconnect`) is "Stopped",
  /// not a timeout (S26).
  public func outcomeLabel(_ code: String) -> String {
    if ActivityOutcome.stopped(code) { return outcomeStopped }
    let base = code.split(separator: ":", maxSplits: 1).first.map(String.init) ?? code
    return outcome(base) ?? outcome("other") ?? code
  }

  public var locale: Locale { Locale(identifier: lang.rawValue) }
}

/// Outcome codes the app reads specially.
public enum ActivityOutcome {
  /// The Shortcut's connection closed before the answer (the run was stopped, or the device left):
  /// nothing timed out and nobody heard the gateway's message.
  public static func stopped(_ code: String) -> Bool { code.hasSuffix(":disconnect") }
  /// The question reached Grok Bot before the Shortcut stopped.
  public static func sent(_ code: String) -> Bool { code.hasPrefix("no-reply:") }
}

public enum L10n {
  /// Tables read from a bundle's compiled lproj folders.
  public static func load(_ lang: Lang, bundle: Bundle = .main) -> Tr {
    Tr(lang: lang, table: table(lang, bundle: bundle), fallback: lang == .en ? [:] : table(.en, bundle: bundle))
  }

  static func table(_ lang: Lang, bundle: Bundle) -> [String: String] {
    guard let url = bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "\(lang.rawValue).lproj"),
          let d = NSDictionary(contentsOf: url) as? [String: String] else { return [:] }
    return d
  }

  /// Every language's table straight from the String Catalog (tests, and runs outside a bundle).
  public static func catalog(_ url: URL) throws -> [Lang: [String: String]] {
    let data = try Data(contentsOf: url)
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let strings = root["strings"] as? [String: Any] else { return [:] }
    var out: [Lang: [String: String]] = [:]
    for (key, v) in strings {
      guard let locs = (v as? [String: Any])?["localizations"] as? [String: Any] else { continue }
      for (code, loc) in locs {
        guard let lang = Lang(rawValue: code), let unit = (loc as? [String: Any])?["stringUnit"] as? [String: Any], let value = unit["value"] as? String else { continue }
        out[lang, default: [:]][key] = value
      }
    }
    return out
  }

  /// The page language for a new user: the first of the Mac's preferred languages Homebot has.
  public static func preferred(_ languages: [String] = Locale.preferredLanguages) -> Lang {
    for id in languages {
      let l = Locale(identifier: id)
      let code = l.language.languageCode?.identifier ?? ""
      let script = l.language.script?.identifier
      let region = l.region?.identifier
      switch code {
      case "zh":
        if script == "Hant" || (script == nil && ["TW", "HK", "MO"].contains(region ?? "")) { return .zhHant }
        return .zhHans
      case "pt": return .ptBR
      default: if let lang = Lang(rawValue: code) { return lang }
      }
    }
    return .en
  }
}
