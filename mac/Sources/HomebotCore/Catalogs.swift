// Spoken catalogs (DESIGN §10, §16, §18.2, DECISIONS 23): the types; the text itself is in
// Catalogs.generated.swift. Spoken catalogs follow the Siri language, not the UI language, so
// they stay code (DESIGN §20.8). The non-English, non-Mandarin catalogs are drafts that no native
// speaker has reviewed yet (STATUS).
import Foundation

/// Spoken system messages (src/core/i18n.ts). Keep them short: Siri reads them aloud.
public struct Messages: Sendable {
  public let busy: @Sendable (String) -> String
  public let inFlight: @Sendable (String) -> String
  public let notSent: String
  public let noReplyInTime: @Sendable (String) -> String
  public let refused: String
  public let unspeakable: String
  /// The reply is (mostly) in a script the Shortcut's voice can't read (DECISIONS item 39).
  public let wrongScript: String
  public let emptyQuestion: String
  public let tooLong: String
  public let badToken: String
  public let forbiddenBot: String
  public let botNotConfigured: String
  public let authFailed: String
  public let upstreamDown: String
  public let rateLimited: String
  public let internalError: String
  /// Conversation mode: the short question after an answer.
  public let more: String
  /// Conversation mode: the run ends on an end word or silence.
  public let goodbye: String
  /// Conversation mode: an unknown, expired or out-of-order run.
  public let restart: String

  /// English for unknown or missing languages.
  public static func of(_ lang: ReplyLang?) -> Messages {
    catalog[lang ?? .en] ?? catalog[.en]!
  }

  public static func of(code: String?) -> Messages {
    of(code.flatMap(ReplyLang.init(rawValue:)) ?? .en)
  }
}

public enum Catalogs {
  /// What the wait-limit probe says after waiting `n` seconds (src/server/voice.ts PROBE_TEXT).
  public static func probeText(_ lang: ReplyLang, _ n: Int) -> String {
    if lang == .ru { return "Подождал \(n) \(ruSeconds(n))." }
    return (probeTextTemplates[lang] ?? probeTextTemplates[.en]!)(n)
  }

  /// Russian plural of "second" for whole numbers (CLDR: one / few / many).
  static func ruSeconds(_ n: Int) -> String {
    let m10 = n % 10, m100 = n % 100
    if m10 == 1 && m100 != 11 { return "секунду" }
    if (2...4).contains(m10) && !(12...14).contains(m100) { return "секунды" }
    return "секунд"
  }

  /// Delays (s) the wait probe cycles through.
  public static let probeSteps = [5, 10, 15, 20, 25, 30, 40, 50, 58]
}
