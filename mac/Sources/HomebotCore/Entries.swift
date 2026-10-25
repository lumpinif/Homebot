// Pure logic over Grok Bot session entries: paging to the real end, and deciding whether a bot
// reply provably belongs to our voice question (DESIGN §4.2, §5.3). No I/O here.
// Ported from src/core/entries.ts.
import Foundation

/// A JSON value kept as it came, for fields whose type the API does not promise (turn flags).
public enum JSONValue: Sendable, Equatable, Codable {
  case bool(Bool)
  case number(Double)
  case string(String)
  case null
  case other

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let b = try? c.decode(Bool.self) { self = .bool(b) }
    else if let n = try? c.decode(Double.self) { self = .number(n) }
    else if let s = try? c.decode(String.self) { self = .string(s) }
    else { self = .other }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .bool(let b): try c.encode(b)
    case .number(let n): try c.encode(n)
    case .string(let s): try c.encode(s)
    case .null, .other: try c.encodeNil()
    }
  }
}

/// A string or a number in the API's JSON, kept as its decimal text (seq values, ids).
struct LooseString: Decodable {
  let value: String

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let s = try? c.decode(String.self) { value = s }
    else if let i = try? c.decode(Int64.self) { value = String(i) }
    else if let d = try? c.decode(Double.self), d.rounded() == d, abs(d) < 9.0e15 { value = String(Int64(d)) }
    else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "expected a string or an integer") }
  }
}

public struct Entry: Sendable, Equatable, Decodable {
  public var seq: String
  public var updatedSeq: String?
  public var kind: String
  public var role: String?
  public var text: String?
  public var createdAtMs: Double?

  public init(seq: String, updatedSeq: String? = nil, kind: String, role: String? = nil, text: String? = nil, createdAtMs: Double? = nil) {
    self.seq = seq
    self.updatedSeq = updatedSeq
    self.kind = kind
    self.role = role
    self.text = text
    self.createdAtMs = createdAtMs
  }

  enum CodingKeys: String, CodingKey { case seq, updatedSeq, kind, role, text, createdAtMs }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    seq = try c.decode(LooseString.self, forKey: .seq).value
    updatedSeq = try c.decodeIfPresent(LooseString.self, forKey: .updatedSeq)?.value
    kind = try c.decode(String.self, forKey: .kind)
    role = try? c.decodeIfPresent(String.self, forKey: .role)
    text = try? c.decodeIfPresent(String.self, forKey: .text)
    createdAtMs = try? c.decodeIfPresent(Double.self, forKey: .createdAtMs)
  }
}

/// Turn flags exactly as a page carries them (probe P1). Only the busy check and the diagnostic
/// trace read them, never ownership (DESIGN §5.1).
public struct Turn: Sendable, Equatable, Decodable {
  public var idle: JSONValue?
  public var inFlight: JSONValue?
  public var queued: JSONValue?

  public init(idle: JSONValue? = nil, inFlight: JSONValue? = nil, queued: JSONValue? = nil) {
    self.idle = idle
    self.inFlight = inFlight
    self.queued = queued
  }

  public static let idleNow = Turn(idle: .bool(true), inFlight: .bool(false), queued: .number(0))
}

public struct Page: Sendable, Equatable, Decodable {
  public var entries: [Entry]
  public var latestUpdatedSeq: String
  public var turn: Turn?

  public init(entries: [Entry], latestUpdatedSeq: String, turn: Turn?) {
    self.entries = entries
    self.latestUpdatedSeq = latestUpdatedSeq
    self.turn = turn
  }

  enum CodingKeys: String, CodingKey { case entries, latestUpdatedSeq, turn }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
    latestUpdatedSeq = try c.decode(LooseString.self, forKey: .latestUpdatedSeq).value
    turn = try? c.decodeIfPresent(Turn.self, forKey: .turn)
  }
}

public struct SyncResult: Sendable, Equatable {
  public var cursor: String
  public var maxSeq: String
  public var entries: [Entry]
  public var turn: Turn?
  public var pages: Int
}

public struct HistoryTooLongError: Error, CustomStringConvertible {
  public let maxPages: Int
  public var description: String { "session history exceeds \(maxPages) pages; raise the page cap" }
}

/// Page `afterUpdatedSeq` from `cursor` until a page is empty or the cursor stops moving. The
/// cursor only advances on non-empty pages (a page's latestUpdatedSeq is that page's end, not
/// the session's latest). `onEntries` receives each page's entries as soon as that page arrives,
/// so evidence from earlier pages survives when a later page fails (BDK re-review R1).
public func syncToEnd(
  cursor start: String, maxSeq: String = "-1", maxPages: Int = 500,
  onEntries: ((([Entry]) -> Void))? = nil,
  fetchPage: (String) async throws -> Page
) async throws -> SyncResult {
  var cursor = start
  var max = try Seq.parse(maxSeq)
  var entries: [Entry] = []
  var turn: Turn?
  var pages = 0
  while true {
    if pages >= maxPages { throw HistoryTooLongError(maxPages: maxPages) }
    let page = try await fetchPage(cursor)
    pages += 1
    turn = page.turn
    onEntries?(page.entries)
    for e in page.entries {
      entries.append(e)
      let s = try Seq.parse(e.seq)
      if s > max { max = s }
    }
    let next = page.latestUpdatedSeq
    if page.entries.isEmpty || next == cursor { break }
    cursor = next
  }
  return SyncResult(cursor: cursor, maxSeq: max.description, entries: entries, turn: turn, pages: pages)
}

public enum Refusal: String, Sendable, Equatable {
  case O2, O3, O5
}

public enum Decision: Sendable, Equatable {
  case waiting
  /// Strict mode: our message is in, and `interim` text deliveries after it carry no echo tag.
  /// They are never spoken; the caller keeps reading until a tagged delivery, the turn's end or
  /// the deadline (DESIGN §4.2).
  case unproved(interim: Int, userSeq: String)
  /// `interim`: untagged deliveries skipped before the accepted one (counts only, never text).
  /// `ended`: the reply starts with our echo tag followed by `[end]` (strict mode only, S25).
  case accept(text: String, userSeq: String, replySeq: String, interim: Int = 0, ended: Bool = false)
  case refuse(Refusal, userSeq: String? = nil, replySeq: String? = nil)
}

/// Decide reply ownership over everything seen since the baseline (DESIGN §4.2).
/// Evidence is judged over EVERY observed version of an entry: a later re-update (e.g. text
/// removed) never erases a version that disqualifies the request. Only the answer text itself
/// comes from the latest non-empty version. `seen`: all entries fetched after the baseline, all
/// versions, in fetch order. Throws on a malformed seq (nothing is accepted then).
public func decideReply(_ seen: [Entry], baseMaxSeq: String, requestId: String, strictEcho: Bool) throws -> Decision {
  let base = try Seq.parse(baseMaxSeq)
  var versions: [Seq: [Entry]] = [:]
  for e in seen {
    let s = try Seq.parse(e.seq)
    if s <= base { continue }
    versions[s, default: []].append(e)
  }
  let seqs = versions.keys.sorted()
  func vs(_ s: Seq) -> [Entry] { versions[s] ?? [] }

  let marker = Envelope.requestMarker(requestId)
  func isOurs(_ e: Entry) -> Bool { e.role == "user" && e.kind == "message" && (e.text?.contains(marker) ?? false) }
  let userSeqs = seqs.filter { vs($0).contains { $0.role == "user" } }
  let ourSeqs = userSeqs.filter { vs($0).contains(where: isOurs) }
  // O2: any user-role entry that is not exactly our one message makes the conversation ambiguous.
  if userSeqs.count > ourSeqs.count || ourSeqs.count > 1 { return .refuse(.O2) }
  guard let userSeq = ourSeqs.first else { return .waiting }

  func hasText(_ e: Entry) -> Bool { e.kind == "send-message" && !(e.text ?? "").trimmingCharacters(in: jsWhitespace).isEmpty }
  // O3: any bot output (text or not; its text may already have been re-updated away before we
  // saw it) between the baseline and our message came from something else.
  if seqs.contains(where: { $0 < userSeq && vs($0).contains { $0.kind == "send-message" } }) {
    return .refuse(.O3, userSeq: userSeq.description)
  }
  let replies = seqs.filter { $0 > userSeq && vs($0).contains(where: hasText) }
  let tag = Envelope.echoTag(requestId)
  func answer(_ text: String) -> String { text.components(separatedBy: tag).joined(separator: " ").trimmingCharacters(in: jsWhitespace) }
  // Any version that carries an echo tag of another request: that output belongs to another
  // question, so nothing in this turn can be told apart from it.
  for s in replies where vs(s).contains(where: { $0.kind == "send-message" && foreignTag($0.text ?? "", tag) }) {
    return .refuse(.O5, userSeq: userSeq.description, replySeq: s.description)
  }
  guard strictEcho else {
    guard let replySeq = replies.first else { return .waiting }
    // replySeq has a version with text, so this is that latest non-empty text.
    return .accept(text: answer(vs(replySeq).filter(hasText).last?.text ?? ""), userSeq: userSeq.description, replySeq: replySeq.description)
  }
  // A delivery that carried our tag in one version and lost it in a later one was replaced by
  // something we can't attribute (BDK review B1). That evidence stays, even if a still later
  // version has the tag again, and is checked for every delivery before any answer is chosen.
  for s in replies {
    let texts = vs(s).filter(hasText)
    if let first = texts.firstIndex(where: { echoed($0.text ?? "", tag) }), texts[first...].contains(where: { !echoed($0.text ?? "", tag) }) {
      return .refuse(.O5, userSeq: userSeq.description, replySeq: s.description)
    }
  }
  // O5: the first delivery whose latest text starts with our tag is the answer. Untagged
  // deliveries before it are interim output (e.g. "checking your mail…") and are skipped, never
  // spoken.
  var interim = 0
  for s in replies {
    let text = vs(s).filter(hasText).last?.text ?? ""
    if echoed(text, tag) {
      return .accept(text: answer(text), userSeq: userSeq.description, replySeq: s.description, interim: interim, ended: endMarked(text, tag))
    }
    interim += 1
  }
  return interim > 0 ? .unproved(interim: interim, userSeq: userSeq.description) : .waiting
}

/// The echo tag must start within the first 40 UTF-16 units of the text.
let echoWindow = 40

func echoed(_ text: String, _ tag: String) -> Bool {
  guard let r = text.range(of: tag, options: .literal) else { return false }
  return text.utf16.distance(from: text.utf16.startIndex, to: r.lowerBound) <= echoWindow
}

/// The bot ends a conversation (S25): the text starts with our echo tag and `[end]` comes right
/// after it. `[end]` anywhere else, or after another tag, ends nothing.
func endMarked(_ text: String, _ tag: String) -> Bool {
  let t = text.drop { $0.isWhitespace }
  guard t.hasPrefix(tag) else { return false }
  return t.dropFirst(tag.count).drop { $0.isWhitespace }.hasPrefix(Envelope.endMark)
}

/// True when the first complete `[hb:…]` tag anywhere in the text is another request's: that
/// delivery answers another question. Other fragments after our own tag are only removed before
/// speech.
func foreignTag(_ text: String, _ ours: String) -> Bool {
  guard let m = text.firstMatch(of: /\[hb:[^\]\s]*\]/) else { return false }
  return m.output != ours
}

/// JavaScript's `trim()` set: Unicode whitespace plus line terminators and BOM.
let jsWhitespace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
