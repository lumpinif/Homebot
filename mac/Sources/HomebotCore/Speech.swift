// Turn bot text into something Siri can read aloud: no markdown, code, links or emoji, and a
// length cap that cuts at a sentence boundary. Ported from src/core/speech.ts with the same
// patterns; JavaScript's \s and \d are spelled out, because ICU's differ.
import Foundation

public enum Speech {
  /// JavaScript's \s.
  static let ws = #"\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}"#

  static let rules: [(NSRegularExpression, String)] = [
    (#"```[\#(ws)\S]*?```"#, " "),
    (#"`([^`]*)`"#, "$1"),
    (#"!\[[^\]]*\]\([^)]*\)"#, ""),
    (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
    (#"https?://[^\#(ws)]+"#, ""),
    (#"(?m)^[\#(ws)]*(?:[#>]+|[-*+]|[0-9]+\.)[\#(ws)]+"#, ""),
    (#"[*_~|]"#, ""),
    (#"[\p{Extended_Pictographic}\p{Emoji_Modifier}\x{FE0F}\x{200D}]"#, ""),
    (#"[\#(ws)]+"#, " "),
  ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

  static let boundary = try! NSRegularExpression(pattern: "[。！？；.!?;]")
  static let trimSet = CharacterSet(charactersIn: "\t\n\u{0B}\u{0C}\r \u{A0}\u{1680}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
    .union(CharacterSet(charactersIn: "\u{2000}"..."\u{200A}"))

  public static func sanitize(_ s: String) -> String {
    var t = s
    for (re, template) in rules {
      t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: template)
    }
    return t.trimmingCharacters(in: trimSet)
  }

  /// `s` must already be sanitized. Counts code points (like the TypeScript spread), cuts at the
  /// last sentence boundary when it lies in the second half, and adds an ellipsis.
  public static func truncate(_ s: String, _ limit: Int) -> String {
    // A bad setting (zero or negative) never traps; at least one character is kept.
    let maxChars = max(limit, 1)
    let scalars = Array(s.unicodeScalars)
    if scalars.count <= maxChars { return s }
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars.prefix(maxChars))
    let head = String(view)
    let ns = head as NSString
    var cut = -1
    for m in boundary.matches(in: head, range: NSRange(location: 0, length: ns.length)) { cut = m.range.location + 1 }
    let body = Double(cut) >= Double(ns.length) / 2 ? ns.substring(to: cut) : head
    return trimEnd(body) + "…"
  }

  public static func speakable(_ s: String, _ maxChars: Int) -> String {
    truncate(sanitize(s), maxChars)
  }

  /// Letters each Speak Text voice can read, by script. Common/Inherited letters (e.g. the
  /// Japanese long-vowel mark) are always fine, and every voice reads Latin, with an accent. A
  /// letter in any other script is read as noise or skipped (an en-US voice read a Chinese answer
  /// as noise on a Mac, S25), so such a reply is never spoken.
  static let unreadable: [ReplyLang: NSRegularExpression] = {
    let extra: [ReplyLang: String] = [
      .ru: #"\p{Script=Cyrillic}"#, .ja: #"\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}"#, .ko: #"\p{Script=Hangul}"#,
      .zhCN: #"\p{Script=Han}"#, .zhTW: #"\p{Script=Han}"#,
    ]
    var m: [ReplyLang: NSRegularExpression] = [:]
    for l in ReplyLang.allCases {
      m[l] = try! NSRegularExpression(pattern: #"[^\P{L}\p{Script=Latin}\p{Script=Common}\p{Script=Inherited}"# + (extra[l] ?? "") + "]")
    }
    return m
  }()

  /// True when the voice of `lang` can read every letter of `s`.
  public static func readable(_ s: String, by lang: ReplyLang) -> Bool {
    unreadable[lang]!.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) == nil
  }

  static func trimEnd(_ s: String) -> String {
    var scalars = Array(s.unicodeScalars)
    while let last = scalars.last, trimSet.contains(last) { scalars.removeLast() }
    var v = String.UnicodeScalarView()
    v.append(contentsOf: scalars)
    return String(v)
  }
}
