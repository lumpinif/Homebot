// One-time download links for a built Shortcut file (DESIGN §7.8). The link id is a 128-bit bearer
// secret: in memory only, single use, 10 minutes, never logged. Served on the voice listener (the
// phone can't reach anything on loopback) at GET /dl/<id>. Ported from src/server/downloads.ts.
import Foundation
import HomebotCore

public actor Downloads {
  public static let linkTTLms: Double = 10 * 60_000

  public struct Link: Sendable, Equatable {
    public var file: URL
    public var name: String
    public var tokenId: String
    public var expiresAt: Double
  }

  var links: [String: Link] = [:]
  let now: @Sendable () -> Double
  let ttlMs: Double

  public init(now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }, ttlMs: Double = Downloads.linkTTLms) {
    self.now = now
    self.ttlMs = ttlMs
  }

  func prune() {
    let t = now()
    links = links.filter { $0.value.expiresAt > t }
  }

  public func create(file: URL, name: String, tokenId: String) -> (id: String, expiresAt: Double) {
    prune()
    let id = Random.base64url(bytes: 16)
    let expiresAt = now() + ttlMs
    links[id] = Link(file: file, name: name, tokenId: tokenId, expiresAt: expiresAt)
    return (id, expiresAt)
  }

  /// Consume a link: returns it at most once, and only before it expires.
  public func take(_ id: String) -> Link? {
    prune()
    guard Downloads.isLinkId(id) else { return nil }
    return links.removeValue(forKey: id)
  }

  /// Drop every link for a token (revoked token, removed bot).
  public func dropToken(_ tokenId: String) {
    links = links.filter { $0.value.tokenId != tokenId }
  }

  /// Drop every link (reset: the files are gone).
  public func dropAll() {
    links = [:]
  }

  public var count: Int {
    prune()
    return links.count
  }

  static func isLinkId(_ id: String) -> Bool {
    id.utf8.count == 22 && id.utf8.allSatisfy { c in
      (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 45 || c == 95
    }
  }
}
