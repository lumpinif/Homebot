// HomebotGateway: the LAN listener (Hummingbird 2 on SwiftNIO, DESIGN §20.2) and the gateway host
// that the app and `homebot start` own. The voice API itself (VoiceAPI) is plain Swift over a
// small request/response pair, so its rules are tested without sockets as well as over HTTP.
import Foundation
import HomebotCore

/// JSON as `JSON.stringify` writes it, for the few shapes the gateway answers with, so a Shortcut
/// gets byte-identical bodies from the Swift and the TypeScript gateway.
public enum JSOut {
  public static func string(_ s: String) -> String {
    var out = "\""
    let units = Array(s.utf16)
    var i = 0
    while i < units.count {
      let u = units[i]
      switch u {
      case 0x22: out += "\\\""
      case 0x5C: out += "\\\\"
      case 0x08: out += "\\b"
      case 0x0C: out += "\\f"
      case 0x0A: out += "\\n"
      case 0x0D: out += "\\r"
      case 0x09: out += "\\t"
      case 0..<0x20: out += String(format: "\\u%04x", u)
      case 0xD800...0xDBFF where i + 1 < units.count && (0xDC00...0xDFFF).contains(units[i + 1]):
        out += String(utf16CodeUnits: [u, units[i + 1]], count: 2)
        i += 1
      case 0xD800...0xDFFF: out += String(format: "\\u%04x", u) // a lone surrogate (well-formed JSON.stringify)
      default: out += String(utf16CodeUnits: [u], count: 1)
      }
      i += 1
    }
    return out + "\""
  }

  /// `{"k":"v",...}` in the given order (string values only).
  public static func object(_ pairs: [(String, String)]) -> String {
    "{" + pairs.map { "\(string($0.0)):\(string($0.1))" }.joined(separator: ",") + "}"
  }

  public static func loop(_ r: LoopResponse) -> String {
    object([("say", r.say), ("ask", r.ask), ("mode", r.mode.rawValue), ("next", r.next.rawValue), ("run", r.run)])
  }
}
