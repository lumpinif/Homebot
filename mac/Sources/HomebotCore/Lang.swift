// Language model (DECISIONS items 3, 22, 23). English is the product default.
// Two independent user settings: the Siri language (what the user speaks and hears; it drives the
// Shortcut phrase, prompt, Speak Text voice, the bot's reply language and the spoken messages;
// bound to each Shortcut's token) and the iPhone language (only the setup steps).
// Ported from src/core/lang.ts.
import Foundation

/// Every language Homebot speaks, in menu order (one table for the UI, iPhone and Siri menus).
public enum Lang: String, CaseIterable, Sendable, Codable {
  case en, es, fr, de, it
  case ptBR = "pt-BR"
  case ru, ja, ko
  case zhHans = "zh-Hans"
  case zhHant = "zh-Hant"

  public struct Info: Sendable {
    /// Named in itself.
    public let name: String
    /// The Siri locale a Shortcut is made for (its Speak Text voice).
    public let siri: String
    /// Key of the spoken catalogs.
    public let reply: ReplyLang
    /// How Siri is woken in that language; "{name}" is the phrase.
    public let hey: String
  }

  public var info: Info {
    switch self {
    case .en: Info(name: "English", siri: "en-US", reply: .en, hey: "Hey Siri, {name}")
    case .es: Info(name: "Español (España)", siri: "es-ES", reply: .es, hey: "Oye Siri, {name}")
    case .fr: Info(name: "Français", siri: "fr-FR", reply: .fr, hey: "Dis Siri, {name}")
    case .de: Info(name: "Deutsch", siri: "de-DE", reply: .de, hey: "Hey Siri, {name}")
    case .it: Info(name: "Italiano", siri: "it-IT", reply: .it, hey: "Ehi Siri, {name}")
    case .ptBR: Info(name: "Português (Brasil)", siri: "pt-BR", reply: .ptBR, hey: "E aí Siri, {name}")
    case .ru: Info(name: "Русский", siri: "ru-RU", reply: .ru, hey: "Привет, Siri, {name}")
    case .ja: Info(name: "日本語", siri: "ja-JP", reply: .ja, hey: "Hey Siri、{name}")
    case .ko: Info(name: "한국어", siri: "ko-KR", reply: .ko, hey: "Siri야, {name}")
    case .zhHans: Info(name: "简体中文", siri: "zh-CN", reply: .zhCN, hey: "嘿Siri，{name}")
    case .zhHant: Info(name: "繁體中文", siri: "zh-TW", reply: .zhTW, hey: "嘿Siri，{name}")
    }
  }

  public static func from(_ code: String?) -> Lang? {
    code.flatMap(Lang.init(rawValue:))
  }
}

/// Keys of the spoken catalogs: one per language. "en" and "zh-CN" predate the table and are kept
/// (tokens, settings and the request line bots see already use them).
public enum ReplyLang: String, CaseIterable, Sendable, Codable {
  case en, es, fr, de, it
  case ptBR = "pt-BR"
  case ru, ja, ko
  case zhCN = "zh-CN"
  case zhTW = "zh-TW"

  /// English for unknown or missing codes.
  public static func from(_ code: String?) -> ReplyLang {
    code.flatMap(ReplyLang.init(rawValue:)) ?? .en
  }
}

public enum Langs {
  /// English Siri locales a Shortcut could be made for before the table had one Siri locale per
  /// language. Their Shortcuts keep working (and keep their accent); the menu no longer offers them.
  public static let legacySiri = ["en-GB", "en-AU", "en-CA", "en-IN", "en-IE", "en-NZ", "en-ZA"]

  public static let defaultSiriLang = "en-US"
  public static let defaultPhoneLang: Lang = .en

  /// Siri locale -> the language it belongs to.
  static let siriToLang: [String: Lang] = {
    var m: [String: Lang] = [:]
    for l in Lang.allCases { m[l.info.siri] = l }
    for s in legacySiri { m[s] = .en }
    return m
  }()

  public static func isSiriLang(_ s: String?) -> Bool {
    s.map { siriToLang[$0] != nil } ?? false
  }

  /// The Siri menu: the same options as the other two menus, valued by Siri locale.
  public static var siriOptions: [(code: String, label: String)] {
    Lang.allCases.map { ($0.info.siri, $0.info.name) }
  }

  /// The language a Siri locale belongs to; English for unknown or missing ones.
  public static func langOfSiri(_ siriLang: String?) -> Lang {
    siriLang.flatMap { siriToLang[$0] } ?? .en
  }

  public static func replyLang(_ siriLang: String?) -> ReplyLang {
    langOfSiri(siriLang).info.reply
  }

  /// What the user says to run a Shortcut, in its Siri language: "Hey Siri, <name>".
  public static func heySiri(_ siriLang: String?, _ name: String) -> String {
    langOfSiri(siriLang).info.hey.replacingOccurrences(of: "{name}", with: name)
  }
}
