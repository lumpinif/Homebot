// Opt-in usage counts, the daily update check and the email sign-up, all against homebot.fun
// (cloud/). Nothing here identifies a Mac: the ping carries closed sets only (no id, no region,
// no free text) and says itself whether it is the first of its week or month, which is how the
// server counts weekly and monthly actives without storing pings. Off unless the user turned it
// on (`Settings.usageCounts`); DO_NOT_TRACK=1 or HOMEBOT_NO_USAGE=1 force it off.
import Foundation

public struct UsagePing: Codable, Sendable, Equatable {
  public var v = 1
  /// The UTC day the flags below were worked out for; the server counts the ping on this day.
  public var day: String
  public var app: String
  public var build: String
  public var os: String
  public var arch: String
  public var lang: String
  public var cohort: String
  public var age: String
  public var use7d: String
  public var newWeek: Bool
  public var newMonth: Bool
  public var first: Bool
}

/// `releases/latest.json` as /api/v1/latest returns it.
public struct LatestRelease: Codable, Sendable, Equatable {
  public var version: String
  public var url: String
  public var sha256: String
  public var notes: String?
}

/// usage.json in the Homebot folder. Local only; never sent.
public struct UsageState: Codable, Sendable, Equatable {
  /// When this Mac first ran Homebot (ms since the epoch); gives the cohort month and the age bucket.
  public var firstRunAt: Double?
  /// UTC day, ISO week and month of the last ping the server accepted.
  public var lastDay: String?
  public var lastWeek: String?
  public var lastMonth: String?
  public var sentFirst = false
  /// The last ping sent, shown under "See what's sent".
  public var lastPing: UsagePing?
  /// UTC day of the last update check and what it found.
  public var checkDay: String?
  public var latest: LatestRelease?

  public init() {}
}

public enum Usage {
  public static let origin = "https://homebot.fun"
  #if HOMEBOT_MAS
  public static let build = "mas"
  #else
  public static let build = "direct"
  #endif
  /// How many recent activity records to read for `answered`; the top bucket is "21+".
  public static let recentLimit = 50

  static var utc: Calendar {
    var c = Calendar(identifier: .iso8601)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }

  public static func day(_ d: Date) -> String {
    let c = utc.dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
  }

  public static func month(_ d: Date) -> String {
    let c = utc.dateComponents([.year, .month], from: d)
    return String(format: "%04d-%02d", c.year!, c.month!)
  }

  public static func isoWeek(_ d: Date) -> String {
    let c = utc.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
    return String(format: "%04d-W%02d", c.yearForWeekOfYear!, c.weekOfYear!)
  }

  public static func ageBucket(days: Int) -> String {
    switch days {
    case ..<2: "0-1d"
    case ..<8: "2-7d"
    case ..<31: "8-30d"
    case ..<91: "31-90d"
    case ..<366: "91-365d"
    default: "1y+"
    }
  }

  public static func use7dBucket(_ n: Int) -> String {
    switch n {
    case 0: "0"
    case ...5: "1-5"
    case ...20: "6-20"
    default: "21+"
    }
  }

  public static func forcedOff(_ env: [String: String]) -> Bool {
    env["DO_NOT_TRACK"] == "1" || env["HOMEBOT_NO_USAGE"] == "1"
  }

  public static var arch: String {
    #if arch(arm64)
    "arm64"
    #else
    "x86_64"
    #endif
  }

  /// Questions answered in the 7 days before `now`, from the newest activity records.
  public static func answered(_ records: [ActivityRecord], now: Date) -> Int {
    let since = (now.timeIntervalSince1970 - 7 * 86_400) * 1000
    return records.filter { $0.at >= since && $0.outcome == "answered" }.count
  }

  /// Today's ping, or nil when one was already accepted today. Pure.
  public static func ping(state: UsageState, now: Date, app: String, os: Int, lang: Lang, answered7d: Int) -> UsagePing? {
    let today = day(now)
    if state.lastDay == today { return nil }
    let firstRun = Date(timeIntervalSince1970: (state.firstRunAt ?? now.timeIntervalSince1970 * 1000) / 1000)
    let days = max(0, Int(now.timeIntervalSince(firstRun) / 86_400))
    return UsagePing(
      day: today, app: app, build: build, os: String(os), arch: arch, lang: lang.rawValue,
      cohort: month(firstRun), age: ageBucket(days: days), use7d: use7dBucket(answered7d),
      newWeek: state.lastWeek != isoWeek(now), newMonth: state.lastMonth != month(now), first: !state.sentFirst
    )
  }

  /// The state after the server accepted `ping` at `now`.
  public static func accepted(_ ping: UsagePing, state: UsageState, now: Date) -> UsageState {
    var s = state
    s.lastDay = day(now)
    s.lastWeek = isoWeek(now)
    s.lastMonth = month(now)
    s.sentFirst = true
    s.lastPing = ping
    return s
  }

  /// Dotted versions compared number by number ("0.10.0" > "0.9.1").
  public static func isNewer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
      let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
      if p != q { return p > q }
    }
    return false
  }
}

/// No cookies, no cache, no redirects, 10 s.
public final class EphemeralTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
  let session: URLSession

  public override init() {
    let c = URLSessionConfiguration.ephemeral
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    c.urlCache = nil
    c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    c.timeoutIntervalForRequest = 10
    c.timeoutIntervalForResource = 10
    c.httpAdditionalHeaders = ["User-Agent": "Homebot"]
    session = URLSession(configuration: c)
  }

  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request, delegate: self)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    if (300..<400).contains(http.statusCode) { throw URLError(.redirectToNonExistentLocation) }
    return (data, http)
  }

  public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
    nil
  }
}

/// Reaches nothing: dev runs and runs with another Homebot folder use it.
public struct OfflineTransport: HTTPTransport {
  public init() {}
  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
}

/// Runs the daily ping and update check. Every failure is ignored: nothing here may slow or
/// break the app, and a failed ping is simply tried again on the next tick.
public actor UsageClient {
  let home: Home
  nonisolated public let transport: HTTPTransport
  let env: [String: String]
  let now: @Sendable () -> Date
  var busy = false

  public init(home: Home, transport: HTTPTransport = EphemeralTransport(), env: [String: String] = ProcessInfo.processInfo.environment, now: @escaping @Sendable () -> Date = Date.init) {
    self.home = home
    self.transport = transport
    self.env = env
    self.now = now
  }

  var file: URL { home.usage }

  public func state() -> UsageState {
    ((try? FileUtil.readJSON(UsageState.self, from: file)) ?? nil) ?? UsageState()
  }

  func save(_ s: UsageState) {
    try? FileUtil.writeJSON(file, s)
  }

  /// Whether pings go out with these settings (the environment can force them off).
  public func countsOn(_ settings: Settings) -> Bool {
    settings.usageCounts == true && !Usage.forcedOff(env)
  }

  /// Call at launch and then every few hours. `answered7d` is read only when a ping goes out.
  public func tick(settings: Settings, app: String, lang: Lang, answered7d: @Sendable () async -> Int) async {
    if busy { return }
    busy = true
    defer { busy = false }
    var s = state()
    let t = now()
    if s.firstRunAt == nil {
      s.firstRunAt = (t.timeIntervalSince1970 * 1000).rounded()
      save(s)
    }
    #if !HOMEBOT_MAS
    if settings.updateCheck != false, s.checkDay != Usage.day(t), let latest = await fetchLatest() {
      s.checkDay = Usage.day(t)
      s.latest = latest
      save(s)
    }
    #endif
    guard countsOn(settings) else { return }
    let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    guard let ping = Usage.ping(state: s, now: t, app: app, os: os, lang: lang, answered7d: await answered7d()) else { return }
    // 204 only once it counted; 429 and 503 leave the state as it was, so the next tick tries again.
    if await post("/api/v1/ping", ping, expect: 204) {
      save(Usage.accepted(ping, state: s, now: t))
    }
  }

  /// The update found by the last check, if newer than `current`.
  public func update(current: String) -> LatestRelease? {
    guard let l = state().latest, Usage.isNewer(l.version, than: current) else { return nil }
    return l
  }

  /// POST /api/v1/subscribe. True when the server took it (it answers the same for any address).
  public func subscribe(email: String, lang: Lang) async -> Bool {
    struct Body: Encodable { let email: String, lang: String, source = "app" }
    return await post("/api/v1/subscribe", Body(email: email, lang: lang.rawValue), expect: 202)
  }

  func fetchLatest() async -> LatestRelease? {
    var r = URLRequest(url: URL(string: Usage.origin + "/api/v1/latest")!)
    r.httpMethod = "GET"
    guard let (data, http) = try? await transport.send(r), http.statusCode == 200 else { return nil }
    return try? JSONDecoder().decode(LatestRelease.self, from: data)
  }

  func post<T: Encodable>(_ path: String, _ body: T, expect: Int) async -> Bool {
    var r = URLRequest(url: URL(string: Usage.origin + path)!)
    r.httpMethod = "POST"
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let enc = JSONEncoder()
    enc.outputFormatting = .sortedKeys
    r.httpBody = try? enc.encode(body)
    guard let (_, http) = try? await transport.send(r) else { return false }
    return http.statusCode == expect
  }
}
