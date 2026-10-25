// The filter every answer passes before it is spoken or stored (DESIGN §20.6 A1): after the
// current echo tag is removed (§4.2), every remaining Homebot protocol fragment goes too (any
// `[hb:…]` tag or bare `hb:…` marker of Homebot's id shape, the envelope's head line and fixed
// sentences), and the exact current API key and the request's token plaintext if they occur.
// The question gets the same treatment before it is stored.
import Foundation

public enum ProtocolFilter {
  static let head = try! NSRegularExpression(pattern: #"\[Homebot (?:voice|test) · hb:[0-9a-f]{12} · [A-Za-z-]{2,8}\]"#)
  static let tag = try! NSRegularExpression(pattern: #"\[hb:[0-9a-f]{12}\]"#)
  static let marker = try! NSRegularExpression(pattern: #"\bhb:[0-9a-f]{12}\b"#)

  /// The envelope's fixed sentences in every language, longest first (turn lines for the turns a
  /// run can have).
  static let fixed: [String] = {
    var s: Set<String> = []
    for st in Envelope.styles.values {
      s.insert(st.intro)
      s.insert(st.style)
      for n in 1...Conversation.steps { s.insert(st.turn(n)) }
    }
    return s.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
  }()

  /// `requestId`: the request whose echo instruction may be quoted back. `secrets`: exact strings
  /// to remove (the API key, the token plaintext); empty ones are ignored.
  public static func clean(_ text: String, requestId: String? = nil, secrets: [String] = []) -> String {
    var t = text
    for s in secrets where s.count >= 8 {
      t = t.replacingOccurrences(of: s, with: "")
    }
    if let requestId {
      for st in Envelope.styles.values {
        t = t.replacingOccurrences(of: st.echo(Envelope.echoTag(requestId)), with: "")
        t = t.replacingOccurrences(of: st.end(Envelope.echoTag(requestId)), with: "")
      }
    }
    for f in fixed { t = t.replacingOccurrences(of: f, with: "") }
    for re in [head, tag, marker] {
      t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
    }
    // Only Homebot reads `[end]` (S25); it is never spoken, wherever it is.
    t = t.replacingOccurrences(of: Envelope.endMark, with: "")
    return t
  }
}
