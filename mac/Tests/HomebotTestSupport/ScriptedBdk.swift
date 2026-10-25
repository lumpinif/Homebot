// Socket-free Grok Bot client for AskService tests whose page responses must be exact: missing or
// malformed turn fields, re-updated entries, output from unrelated tasks. The fake API
// (FakeGrokBot) stays the transport test double. Ported from test-helpers/scripted-bdk.ts.
import Foundation
import HomebotCore

public struct ScriptedPage: Sendable {
  /// Serve a transient failure (HTTP 503) instead of a page.
  public var fail = false
  public var entries: [Entry]
  /// Exactly what the page carries; nil = no turn field at all.
  public var turn: Turn?

  public init(fail: Bool = false, entries: [Entry], turn: Turn?) {
    self.fail = fail
    self.entries = entries
    self.turn = turn
  }

  public static let failing = ScriptedPage(fail: true, entries: [], turn: .idleNow)
}

/// The baseline sees an empty, idle session at cursor `tail`. After the send, each GET serves the
/// next page from `script(sent)`; once the script is used up, GETs return empty pages with the last
/// page's turn. One poll pages until an empty page, so an empty scripted page marks the end of a
/// poll. `before`: pages served before the send (the baseline and any follow-up idle wait).
public final class ScriptedBdk: BdkClient, @unchecked Sendable {
  public struct Sent: Sendable {
    public let messageId: String
    public let text: String
  }

  private let lock = NSLock()
  private let script: @Sendable (Sent) -> [ScriptedPage]
  private let tail: String
  private var pre: [ScriptedPage]
  private var pages: [ScriptedPage]?
  private var lastTurn: Turn? = .idleNow
  private var counter = 1000
  private var _sent = 0
  private var _fetchedAfterSend = 0
  /// Replaces getEntries (error tests).
  public var entriesOverride: (@Sendable () async throws -> Page)?

  public init(tail: String = "100", before: [ScriptedPage] = [], _ script: @escaping @Sendable (Sent) -> [ScriptedPage]) {
    self.script = script
    self.tail = tail
    pre = before
  }

  public var sent: Int { lock.withLock { _sent } }
  public var fetchedAfterSend: Int { lock.withLock { _fetchedAfterSend } }
  public var remaining: Int { lock.withLock { pages?.count ?? 0 } }
  /// Pages of `before` not served yet.
  public var beforeRemaining: Int { lock.withLock { pre.count } }

  private func serve(_ next: ScriptedPage, _ cursor: String) throws -> Page {
    if next.fail { throw BdkError(message: "scripted BDK: transient failure", kind: .upstream, status: 503) }
    lastTurn = next.turn
    let entries = next.entries.map { e -> Entry in
      var c = e
      counter += 1
      c.updatedSeq = String(counter)
      return c
    }
    return Page(entries: entries, latestUpdatedSeq: entries.last?.updatedSeq ?? cursor, turn: next.turn)
  }

  public func getOrCreateSession(name: String) async throws -> NamedSession {
    throw BdkError(message: "scripted BDK: getOrCreateSession is not part of these tests", kind: .request, status: nil)
  }

  public func getEntries(sessionId: String, afterUpdatedSeq cursor: String) async throws -> Page {
    if let o = entriesOverride { return try await o() }
    return try lock.withLock {
      guard pages != nil else {
        if !pre.isEmpty { return try serve(pre.removeFirst(), cursor) }
        return Page(entries: [], latestUpdatedSeq: cursor == "-1" ? tail : cursor, turn: .idleNow)
      }
      _fetchedAfterSend += 1
      guard !pages!.isEmpty else { return Page(entries: [], latestUpdatedSeq: cursor, turn: lastTurn) }
      return try serve(pages!.removeFirst(), cursor)
    }
  }

  public func sendMessage(sessionId: String, messageId: String, text: String) async throws -> SendResult {
    let p = script(Sent(messageId: messageId, text: text))
    lock.withLock {
      _sent += 1
      pages = p
    }
    return SendResult(delivery: "accepted_temporal")
  }
}

public enum Script {
  public static let busy = Turn(idle: .bool(false), inFlight: .bool(true), queued: .number(0))
  public static func ours(_ seq: Int, _ sent: ScriptedBdk.Sent) -> Entry { Entry(seq: String(seq), kind: "message", role: "user", text: sent.text) }
  public static func reply(_ seq: Int, _ text: String) -> Entry { Entry(seq: String(seq), kind: "send-message", text: text) }
  public static func page(_ entries: [Entry], _ turn: Turn? = .idleNow) -> ScriptedPage { ScriptedPage(entries: entries, turn: turn) }
  public static func end(_ turn: Turn? = .idleNow) -> ScriptedPage { ScriptedPage(entries: [], turn: turn) }
}
