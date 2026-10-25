// Minimal XML property-list writer: only the types a Shortcut uses (dict, array, string, integer,
// boolean), with dictionary keys in insertion order. Not a general plist library (DESIGN D6).
// Its output is byte-for-byte the TypeScript writer's (src/shortcut/plist.ts) for the same value.
import Foundation

public indirect enum PlistValue: Sendable, Equatable {
  case string(String)
  case integer(Int64)
  case bool(Bool)
  case array([PlistValue])
  /// Ordered: the order is part of the bytes.
  case dict([(String, PlistValue)])

  public static func == (a: PlistValue, b: PlistValue) -> Bool {
    switch (a, b) {
    case (.string(let x), .string(let y)): return x == y
    case (.integer(let x), .integer(let y)): return x == y
    case (.bool(let x), .bool(let y)): return x == y
    case (.array(let x), .array(let y)): return x == y
    case (.dict(let x), .dict(let y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    default: return false
    }
  }

  /// The value under `key` of a dict.
  public subscript(key: String) -> PlistValue? {
    if case .dict(let items) = self { return items.first { $0.0 == key }?.1 }
    return nil
  }

  public var stringValue: String? {
    if case .string(let s) = self { return s }
    return nil
  }

  public var arrayValue: [PlistValue]? {
    if case .array(let a) = self { return a }
    return nil
  }
}

public struct PlistError: Error, CustomStringConvertible, Equatable {
  public let description: String
}

public enum Plist {
  static func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
  }

  /// XML 1.0 forbids most C0 control characters even when escaped, and U+FFFE/U+FFFF.
  static func invalidXML(_ s: String) -> Bool {
    s.unicodeScalars.contains { c in
      let v = c.value
      return v <= 0x08 || v == 0x0B || v == 0x0C || (v >= 0x0E && v <= 0x1F) || v == 0xFFFE || v == 0xFFFF
    }
  }

  static func node(_ v: PlistValue, _ pad: String) throws -> String {
    let inner = pad + "\t"
    switch v {
    case .string(let s):
      if invalidXML(s) { throw PlistError(description: "plist string contains a character XML cannot represent") }
      return "\(pad)<string>\(esc(s))</string>"
    case .bool(let b):
      return "\(pad)<\(b)/>"
    case .integer(let n):
      // The TypeScript writer accepts safe integers only.
      guard abs(n) <= 9_007_199_254_740_991 else { throw PlistError(description: "plist writer supports safe integers only") }
      return "\(pad)<integer>\(n)</integer>"
    case .array(let a):
      if a.isEmpty { return "\(pad)<array/>" }
      return "\(pad)<array>\n\(try a.map { try node($0, inner) }.joined(separator: "\n"))\n\(pad)</array>"
    case .dict(let items):
      if items.isEmpty { return "\(pad)<dict/>" }
      let body = try items.map { "\(inner)<key>\(esc($0.0))</key>\n\(try node($0.1, inner))" }.joined(separator: "\n")
      return "\(pad)<dict>\n\(body)\n\(pad)</dict>"
    }
  }

  /// Serialize to an XML plist document.
  public static func xml(_ root: PlistValue) throws -> String {
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      + "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
      + "<plist version=\"1.0\">\n"
      + (try node(root, ""))
      + "\n</plist>\n"
  }
}
