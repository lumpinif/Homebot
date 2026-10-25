// Thin HTTP client for the (undocumented) Grok Bot sessions API (DESIGN §5.1). All Grok Bot HTTP
// goes through here, over an injectable transport (URLSession in the app, an in-process fake in
// tests). Errors never include the key or response bodies. Cancellation of the calling task
// replaces the TypeScript AbortSignal. Ported from src/core/bdk.ts.
import Foundation

public struct BdkError: Error, CustomStringConvertible, Equatable {
  public enum Kind: String, Sendable { case auth, upstream, network, request }

  public let message: String
  public let kind: Kind
  public let status: Int?

  public var description: String { message }

  public init(message: String, kind: Kind, status: Int?) {
    self.message = message
    self.kind = kind
    self.status = status
  }
}

/// Get-or-create response (DESIGN §5.1).
public struct NamedSession: Sendable, Equatable, Decodable {
  public var id: String
  public var name: String?
  public var createdAtMs: Double?
  public var latestUpdatedSeq: String?

  enum CodingKeys: String, CodingKey { case id, name, createdAtMs, latestUpdatedSeq }

  public init(id: String, name: String? = nil, createdAtMs: Double? = nil, latestUpdatedSeq: String? = nil) {
    self.id = id
    self.name = name
    self.createdAtMs = createdAtMs
    self.latestUpdatedSeq = latestUpdatedSeq
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = (try? c.decode(LooseString.self, forKey: .id).value) ?? ""
    name = try? c.decodeIfPresent(String.self, forKey: .name)
    createdAtMs = try? c.decodeIfPresent(Double.self, forKey: .createdAtMs)
    latestUpdatedSeq = try? c.decodeIfPresent(LooseString.self, forKey: .latestUpdatedSeq)?.value
  }
}

public struct SendResult: Sendable, Equatable, Decodable {
  /// Absent when the response carries none (treated as accepted, DESIGN §4.1 step 10).
  public var delivery: String?

  public init(delivery: String?) { self.delivery = delivery }
}

public protocol BdkClient: Sendable {
  /// Get-or-create a bot by its EXACT name. Creates a new empty bot on a typo, so callers must
  /// confirm the name first and check `justCreated` (resolveBotByName).
  func getOrCreateSession(name: String) async throws -> NamedSession
  /// `sessionId`: numeric session id.
  func getEntries(sessionId: String, afterUpdatedSeq: String) async throws -> Page
  func sendMessage(sessionId: String, messageId: String, text: String) async throws -> SendResult
}

/// One HTTP exchange. Implementations must not follow redirects.
public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession transport that refuses redirects (the TypeScript `redirect: "error"`).
public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate {
  public override init() {}

  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await URLSession.shared.data(for: request, delegate: self)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    if (300..<400).contains(http.statusCode) { throw URLError(.redirectToNonExistentLocation) }
    return (data, http)
  }

  public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
    nil
  }
}

public struct HTTPBdkClient: BdkClient {
  public static let defaultBaseURL = "https://api.cursor.com/v0/grokbot/sessions"

  let key: String
  let baseURL: String
  let transport: HTTPTransport
  let callTimeoutMs: Int

  public init(key: String, baseURL: String = HTTPBdkClient.defaultBaseURL, transport: HTTPTransport = URLSessionTransport(), callTimeoutMs: Int = 10_000) {
    self.key = key
    self.baseURL = baseURL
    self.transport = transport
    self.callTimeoutMs = callTimeoutMs
  }

  /// Path segments and query values are percent-encoded like JavaScript's encodeURIComponent.
  static func component(_ s: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
  }

  func call<T: Decodable & Sendable>(_ method: String, _ path: String, _ body: [String: String]?) async throws -> T {
    guard let url = URL(string: baseURL + path) else { throw BdkError(message: "BDK \(method) \(redact(path)) failed: bad URL", kind: .request, status: nil) }
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.setValue("agent-serve", forHTTPHeaderField: "x-cursor-client-type")
    req.timeoutInterval = Double(callTimeoutMs) / 1000
    if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) }
    let transport = self.transport
    let request = req
    let result: (Data, HTTPURLResponse)
    do {
      // A hard limit, also for a transport that ignores cancellation.
      result = try await Deadline.run(ms: callTimeoutMs) { try await transport.send(request) }
    } catch is Deadline.Expired {
      throw BdkError(message: "BDK \(method) \(redact(path)) failed: TimeoutError", kind: .network, status: nil)
    } catch {
      if Task.isCancelled { throw CancellationError() }
      throw BdkError(message: "BDK \(method) \(redact(path)) failed: \(Log.errorName(error))", kind: .network, status: nil)
    }
    let (data, res) = result
    if (200..<300).contains(res.statusCode) {
      do {
        return try JSONDecoder().decode(T.self, from: data)
      } catch {
        throw BdkError(message: "BDK \(method) \(redact(path)) returned an unexpected body", kind: .upstream, status: res.statusCode)
      }
    }
    let kind: BdkError.Kind = res.statusCode == 401 || res.statusCode == 403 ? .auth : res.statusCode >= 500 || res.statusCode == 429 ? .upstream : .request
    throw BdkError(message: "BDK \(method) \(redact(path)) -> \(res.statusCode)", kind: kind, status: res.statusCode)
  }

  /// Keep only the shape of a path in error messages (no query values).
  func redact(_ p: String) -> String {
    p.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
  }

  public func getOrCreateSession(name: String) async throws -> NamedSession {
    try await call("POST", "", ["name": name])
  }

  public func getEntries(sessionId: String, afterUpdatedSeq: String) async throws -> Page {
    try await call("GET", "/\(Self.component(sessionId))/entries?afterUpdatedSeq=\(Self.component(afterUpdatedSeq))", nil)
  }

  public func sendMessage(sessionId: String, messageId: String, text: String) async throws -> SendResult {
    try await call("POST", "/\(Self.component(sessionId))/messages", ["messageId": messageId, "text": text])
  }
}
