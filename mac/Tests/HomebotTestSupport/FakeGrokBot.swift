// In-process fake of the Grok Bot sessions API, shaped like the real one as observed in the
// spike: numeric seq/updatedSeq as strings, 200 entries per page, `duplicate` on a reused
// messageId. It is an HTTPTransport, so HTTPBdkClient runs unchanged against it: requests are
// real URLRequests and responses real JSON bodies. Ported from test-helpers/fake-bdk.ts.
import Foundation
import HomebotCore

public final class FakeGrokBot: HTTPTransport, @unchecked Sendable {
  public static let key = "test-key-not-a-secret"
  public static let baseURL = "http://fake.invalid/v0/grokbot/sessions"

  public struct FakeEntry: Sendable, Codable {
    public var seq: String
    public var updatedSeq: String
    public var createdAtMs: Double
    public var kind: String
    public var role: String?
    public var text: String?
  }

  public struct Session {
    public var entries: [FakeEntry] = []
    public var idle = true
    public var ids: Set<String> = []
    public var queued = 0
    /// A turn is running (autoReply sets this from the message until its last delivery).
    public var working = false
  }

  public struct Request: Sendable {
    public var method: String
    public var path: String
    public var query: String?
    public var auth: String?
    public var client: String?
    public var contentType: String?
    public var body: [String: String]
  }

  public struct Post: Sendable, Equatable {
    public var sid: String
    public var messageId: String
    public var text: String

    public init(sid: String, messageId: String, text: String) {
      self.sid = sid
      self.messageId = messageId
      self.text = text
    }
  }

  /// What `intercept` may do to a request: drop the connection, answer with a status, or (for a
  /// message POST) store the message and then drop the connection.
  public enum Action: Sendable {
    case destroy
    case acceptThenDestroy
    case status(Int)
    /// Answer 200 with this raw body.
    case body(String)
  }

  public init() {}

  private let lock = NSLock()
  private var counter = 1000
  private var sessions: [String: Session] = [:]
  private var _posts: [Post] = []
  private var _requests: [Request] = []
  private var _names: [String: (sid: String, createdAtMs: Double)] = [:]
  private var _created: [String] = []
  private var _delivery: String? = "accepted_temporal"
  private var _intercept: (@Sendable (_ method: String, _ what: String, _ sid: String?, _ attempt: Int) async -> Action?)?
  private var onMessage: (@Sendable (String, String) -> Void)?

  public var posts: [Post] { lock.withLock { _posts } }
  public var requests: [Request] { lock.withLock { _requests } }
  public var created: [String] { lock.withLock { _created } }
  public var delivery: String? {
    get { lock.withLock { _delivery } }
    set { lock.withLock { _delivery = newValue } }
  }
  public var intercept: (@Sendable (_ method: String, _ what: String, _ sid: String?, _ attempt: Int) async -> Action?)? {
    get { lock.withLock { _intercept } }
    set { lock.withLock { _intercept = newValue } }
  }

  public func client(key: String = FakeGrokBot.key, callTimeoutMs: Int = 10_000) -> HTTPBdkClient {
    HTTPBdkClient(key: key, baseURL: FakeGrokBot.baseURL, transport: self, callTimeoutMs: callTimeoutMs)
  }

  public func session(_ sid: String) -> Session {
    lock.withLock { sessions[sid, default: Session()] }
  }

  @discardableResult
  public func add(_ sid: String, kind: String, role: String? = nil, text: String? = nil, createdAtMs: Double? = nil) -> FakeEntry {
    lock.withLock { addLocked(sid, kind: kind, role: role, text: text, createdAtMs: createdAtMs) }
  }

  private func addLocked(_ sid: String, kind: String, role: String?, text: String?, createdAtMs: Double?) -> FakeEntry {
    counter += 1
    let e = FakeEntry(seq: String(counter), updatedSeq: String(counter), createdAtMs: createdAtMs ?? Date().timeIntervalSince1970 * 1000, kind: kind, role: role, text: text)
    sessions[sid, default: Session()].entries.append(e)
    return e
  }

  /// Entries recorded elsewhere (the TypeScript fake's transcripts), with their sequence numbers;
  /// later entries continue after the highest one.
  public func load(_ sid: String, _ entries: [FakeEntry]) {
    lock.withLock {
      sessions[sid, default: Session()].entries.append(contentsOf: entries)
      for e in entries { counter = max(counter, Int(e.seq) ?? 0, Int(e.updatedSeq) ?? 0) }
    }
  }

  /// Re-update an old entry (it comes back with a new updatedSeq).
  public func touch(_ sid: String, seq: String, text: String?? = nil, role: String?? = nil) {
    lock.withLock {
      guard let i = sessions[sid]?.entries.firstIndex(where: { $0.seq == seq }) else { fatalError("fake: no entry \(seq) in session \(sid)") }
      if let text { sessions[sid]!.entries[i].text = text }
      if let role { sessions[sid]!.entries[i].role = role }
      counter += 1
      sessions[sid]!.entries[i].updatedSeq = String(counter)
    }
  }

  public func setQueued(_ sid: String, _ n: Int) {
    lock.withLock { sessions[sid, default: Session()].queued = n }
  }

  /// Run `fn` for every new message (instead of an auto-reply).
  public func setOnMessage(_ fn: @escaping @Sendable (_ sid: String, _ text: String) -> Void) {
    lock.withLock { onMessage = fn }
  }

  public func setIdle(_ sid: String, _ idle: Bool) {
    lock.withLock { sessions[sid, default: Session()].idle = idle }
  }

  /// An existing named bot (created long ago unless `createdAtMs` is given).
  public func addNamed(_ name: String, sid: String, createdAtMs: Double? = nil) {
    lock.withLock {
      _ = sessions[sid, default: Session()]
      sessions[sid] = sessions[sid] ?? Session()
      _names[name] = (sid, createdAtMs ?? Date().timeIntervalSince1970 * 1000 - 86_400_000)
    }
  }

  /// Reply as the bot `ms` after each new message, echoing the request tag if `echo`. `interim`
  /// are untagged progress deliveries before the reply, `more` further deliveries after it, all
  /// `gapMs` apart. While the turn runs, `turn` reports busy unless `reportsBusy` is false; it
  /// goes idle `settleMs` after the last delivery.
  public func autoReply(_ sid: String, ms: Int = 20, text: String = "现在三点。", echo: Bool = true, interim: [String] = [], more: [String] = [], gapMs: Int = 20, settleMs: Int = 0, reportsBusy: Bool = true) {
    let sleep: @Sendable (Int) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) }
    lock.withLock {
      onMessage = { [weak self] s, msg in
        guard let self, s == sid else { return }
        let id = msg.firstMatch(of: /hb:([0-9a-f]{12})/).map { String($0.1) } ?? ""
        if reportsBusy { self.lock.withLock { self.sessions[sid, default: Session()].working = true } }
        Task {
          await sleep(ms)
          for t in interim {
            self.add(sid, kind: "send-message", text: t)
            await sleep(gapMs)
          }
          self.add(sid, kind: "send-message", text: echo ? "[hb:\(id)] \(text)" : text)
          for t in more {
            await sleep(gapMs)
            self.add(sid, kind: "send-message", text: t)
          }
          await sleep(settleMs)
          self.lock.withLock { self.sessions[sid, default: Session()].working = false }
        }
      }
    }
  }

  // MARK: HTTPTransport

  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try Task.checkCancellation()
    guard let url = request.url else { throw URLError(.badURL) }
    let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let path = url.path
    let method = request.httpMethod ?? "GET"
    let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: String]) ?? [:]
    let req = Request(method: method, path: path, query: comps?.query, auth: request.value(forHTTPHeaderField: "authorization"), client: request.value(forHTTPHeaderField: "x-cursor-client-type"), contentType: request.value(forHTTPHeaderField: "content-type"), body: body)
    let attempt = lock.withLock { () -> Int in
      _requests.append(req)
      return _requests.filter { $0.path == path && $0.method == method }.count
    }
    func reply(_ status: Int, _ obj: Any) throws -> (Data, HTTPURLResponse) {
      let data = try JSONSerialization.data(withJSONObject: obj)
      return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["content-type": "application/json"])!)
    }
    guard req.auth == "Bearer \(FakeGrokBot.key)" else { return try reply(401, ["error": "unauthorized"]) }

    if path == "/v0/grokbot/sessions" && method == "POST" {
      if let act = await intercept?("POST", "sessions", nil, attempt) {
        if case .status(let s) = act { return try reply(s, ["error": "injected"]) }
        if case .body(let b) = act { return (Data(b.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
        throw URLError(.networkConnectionLost)
      }
      // Get-or-create by exact name, like the real route: an unknown name creates an empty bot.
      let name = body["name"] ?? ""
      let (sid, createdAtMs, latest) = lock.withLock { () -> (String, Double, String) in
        var named = _names[name]
        if named == nil {
          named = (String(900_000 + _names.count), Date().timeIntervalSince1970 * 1000)
          _names[name] = named
          _created.append(name)
        }
        let es = sessions[named!.sid, default: Session()].entries
        let latest = es.map { try! Seq.parse($0.updatedSeq) }.max()?.description ?? "-1"
        return (named!.sid, named!.createdAtMs, latest)
      }
      return try reply(200, ["id": Int(sid)!, "name": name, "createdAtMs": createdAtMs, "latestUpdatedSeq": latest])
    }

    let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard parts.count == 5, parts[0] == "v0", parts[1] == "grokbot", parts[2] == "sessions", ["entries", "messages"].contains(parts[4]) else {
      return try reply(404, ["error": "not found"])
    }
    let sid = parts[3].removingPercentEncoding ?? parts[3]
    let what = parts[4]
    let act = await intercept?(method, what, sid, attempt)
    // Like URLSession: a cancelled request fails instead of answering.
    if Task.isCancelled { throw URLError(.cancelled) }
    switch act {
    case .destroy: throw URLError(.networkConnectionLost)
    case .status(let s): return try reply(s, ["error": "injected"])
    case .body(let b): return (Data(b.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    default: break
    }

    if what == "entries" && method == "GET" {
      let afterRaw = comps?.queryItems?.first { $0.name == "afterUpdatedSeq" }?.value ?? "-1"
      let after = try Seq.parse(afterRaw)
      let (page, turn) = lock.withLock { () -> ([FakeEntry], [String: Any]) in
        let s = sessions[sid, default: Session()]
        let page = s.entries
          .filter { (try? Seq.parse($0.updatedSeq)).map { $0 > after } ?? false }
          .sorted { try! Seq.parse($0.updatedSeq) < Seq.parse($1.updatedSeq) }
          .prefix(200)
        return (Array(page), ["idle": s.idle && !s.working, "inFlight": !s.idle || s.working, "queued": s.queued])
      }
      let entries: [[String: Any]] = page.map { e in
        var d: [String: Any] = ["seq": e.seq, "updatedSeq": e.updatedSeq, "createdAtMs": e.createdAtMs, "kind": e.kind]
        if let r = e.role { d["role"] = r }
        if let t = e.text { d["text"] = t }
        return d
      }
      return try reply(200, ["entries": entries, "latestUpdatedSeq": page.last?.updatedSeq ?? afterRaw, "turn": turn])
    }
    if what == "messages" && method == "POST" {
      let messageId = body["messageId"] ?? ""
      let text = body["text"] ?? ""
      let (dup, notify, delivery) = lock.withLock { () -> (Bool, (@Sendable (String, String) -> Void)?, String?) in
        if sessions[sid, default: Session()].ids.contains(messageId) { return (true, nil, nil) }
        sessions[sid, default: Session()].ids.insert(messageId)
        _posts.append(Post(sid: sid, messageId: messageId, text: text))
        _ = addLocked(sid, kind: "message", role: "user", text: text, createdAtMs: nil)
        return (false, onMessage, _delivery)
      }
      if dup { return try reply(200, ["delivery": "duplicate"]) }
      notify?(sid, text)
      if case .acceptThenDestroy = act { throw URLError(.networkConnectionLost) }
      return try reply(200, delivery.map { ["delivery": $0] } ?? [:])
    }
    return try reply(405, ["error": "method"])
  }
}
