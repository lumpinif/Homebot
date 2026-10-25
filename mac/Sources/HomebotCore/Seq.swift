// Grok Bot sequence numbers are decimal strings of any length (the TypeScript version compared
// them as BigInt). Compared exactly here, never as strings or doubles.
import Foundation

public struct Seq: Comparable, Hashable, Sendable, CustomStringConvertible {
  let negative: Bool
  /// Digits without leading zeros ("0" for zero).
  let digits: String

  public init?(_ s: String) {
    var t = Substring(s)
    var neg = false
    if t.first == "-" {
      neg = true
      t = t.dropFirst()
    }
    guard !t.isEmpty, t.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
    let stripped = t.drop(while: { $0 == "0" })
    digits = stripped.isEmpty ? "0" : String(stripped)
    negative = neg && digits != "0"
  }

  /// A seq that must be well formed (throws like the TypeScript BigInt conversion did).
  public static func parse(_ s: String) throws -> Seq {
    guard let v = Seq(s) else { throw SeqError() }
    return v
  }

  public var description: String { negative ? "-" + digits : digits }

  public static func < (a: Seq, b: Seq) -> Bool {
    if a.negative != b.negative { return a.negative }
    let less = a.digits.count != b.digits.count ? a.digits.count < b.digits.count : a.digits < b.digits
    let equal = a.digits == b.digits
    return a.negative ? (!less && !equal) : less
  }
}

public struct SeqError: Error, CustomStringConvertible {
  public var description: String { "Grok Bot returned a malformed sequence number" }
}
