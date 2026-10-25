// The text Homebot sends to a bot (DESIGN §5.4, §18.4). Line 1 is a stable marker bots can key
// on; `hb:<id>` lets us find our own user entry. The echoed `[hb:<id>]` is evidence (not proof)
// that a reply answers this request; see DESIGN §4.2 for its limits. Ported from
// src/core/envelope.ts.
import Foundation

public enum Envelope {
  struct Style: Sendable {
    let intro: String
    let echo: @Sendable (String) -> String
    let style: String
    let end: @Sendable (String) -> String
    let statement: String
    let close: String
  }

  /// 12 hex characters from 6 random bytes.
  public static func newRequestId() -> String { Random.hex(bytes: 6) }
  public static func requestMarker(_ id: String) -> String { "hb:\(id)" }
  public static func echoTag(_ id: String) -> String { "[hb:\(id)]" }
  /// Written by the bot right after its echo tag when the user is ending a conversation (S25).
  public static let endMark = "[end]"

  /// Languages written without spaces between sentences.
  static let unspaced: Set<ReplyLang> = [.zhCN, .zhTW, .ja]

  /// `style`: `.standard` uses the language's default hint, `.none` drops it, `.custom` replaces it.
  /// `turn`: the bot turn within a conversation run (DESIGN §18.4); nil for one-shot questions.
  public static func build(id: String, text: String, lang: ReplyLang, strictEcho: Bool, style: StyleHint = .standard, test: Bool = false, turn: Int? = nil) -> String {
    let s = styles[lang] ?? styles[.en]!
    let head = "[Homebot \(test ? "test" : "voice") · \(requestMarker(id)) · \(lang.rawValue)]"
    let styleText: String
    switch style {
    case .standard: styleText = s.style
    case .none: styleText = ""
    case .custom(let c): styleText = c
    }
    // A conversation turn may end the run: `[end]` counts only right after the echo tag (S25). A
    // one-shot question can't be answered back, so it ends on a statement.
    let inTurn = turn.map { $0 != 0 } ?? false
    let ending = inTurn ? (strictEcho ? s.end(echoTag(id)) : "") : s.statement
    let parts = [s.intro, strictEcho ? s.echo(echoTag(id)) : "", styleText, ending]
    let hint = parts.filter { !$0.isEmpty }.joined(separator: unspaced.contains(lang) ? "" : " ")
    return "\(head)\n\(text)\n\n\(hint)\(s.close)"
  }
}
