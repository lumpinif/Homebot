// Bot setup helpers. Cold sync walks a session's whole history once (at setup, never in the
// voice path) so later requests can start from a warm cursor (DESIGN §5.3, §6.3). Add-by-name
// resolves an exact name with get-or-create (DECISIONS item 13). Ported from src/core/bots.ts.
import Foundation

public struct ColdSync: Sendable, Equatable {
  public var cursor: String
  public var maxSeq: String
  public var pages: Int
  public var entryCount: Int
  public var turn: Turn?
  public var latestBotText: String?
}

public struct BotSetupError: Error, CustomStringConvertible, Equatable {
  public let description: String
}

public enum Bots {
  public static let justCreatedMs: Double = 60_000

  /// Resolve an EXACT bot name with get-or-create. Detects the typo case the way the official
  /// extension does: an empty session (latestUpdatedSeq "-1") created in the last 60 s was most
  /// likely created by this very call. Callers must have confirmed the exact name with the user
  /// first, and must not add a just-created bot.
  public static func resolveByName(_ bdk: BdkClient, name: String, now: @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) async throws -> (sessionId: String, justCreated: Bool) {
    let r = try await bdk.getOrCreateSession(name: name)
    guard !r.id.isEmpty, r.id.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
      throw BotSetupError(description: "Grok Bot returned an unexpected bot id")
    }
    let justCreated = r.latestUpdatedSeq == "-1" && r.createdAtMs.map { now() - $0 < justCreatedMs } == true
    return (r.id, justCreated)
  }

  /// Read-only: proves the session id exists and the key can read it, and returns the cursor.
  /// Bounded by a page cap AND a total time cap.
  public static func coldSync(_ bdk: BdkClient, sessionId: String, maxPages: Int = 500, timeoutMs: Int = 120_000) async throws -> ColdSync {
    let r: SyncResult
    do {
      r = try await Deadline.run(ms: timeoutMs) {
        try await syncToEnd(cursor: "-1", maxPages: maxPages) { cursor in
          try Task.checkCancellation()
          return try await bdk.getEntries(sessionId: sessionId, afterUpdatedSeq: cursor)
        }
      }
    } catch is Deadline.Expired {
      throw BotSetupError(description: "reading the session history took longer than \(Int((Double(timeoutMs) / 1000).rounded())) s; try again later")
    }
    let latest = try r.entries
      .filter { $0.kind == "send-message" && !($0.text ?? "").trimmingCharacters(in: jsWhitespace).isEmpty }
      .map { (try Seq.parse($0.seq), $0) }
      .sorted { $0.0 < $1.0 }
      .last?.1.text
    return ColdSync(cursor: r.cursor, maxSeq: r.maxSeq, pages: r.pages, entryCount: r.entries.count, turn: r.turn, latestBotText: latest)
  }
}
