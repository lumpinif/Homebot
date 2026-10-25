// Opt-in usage counts: the exact ping the server accepts, its buckets and week/month flags,
// nothing sent without consent, and the update check and sign-up requests.
import Foundation
import Testing

@testable import HomebotCore
import HomebotTestSupport

final class RecordingTransport: HTTPTransport, @unchecked Sendable {
  var requests: [URLRequest] = []
  var status: (URLRequest) -> Int
  var body: Data

  init(status: @escaping (URLRequest) -> Int = { $0.httpMethod == "GET" ? 200 : 204 }, body: Data = Data()) {
    self.status = status
    self.body = body
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let code = status(request)
    return (body, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
  }
}

@Suite("Usage")
struct UsageTests {
  static func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

  final class Clock: @unchecked Sendable {
    var now: Date
    init(_ iso: String) { now = UsageTests.date(iso) }
  }

  func client(_ t: RecordingTransport, _ clock: Clock, env: [String: String] = [:]) throws -> (UsageClient, Home) {
    let home = try Home(root: try tmpDir().appendingPathComponent("hb", isDirectory: true))
    try home.prepare()
    return (UsageClient(home: home, transport: t, env: env, now: { clock.now }), home)
  }

  func on(_ counts: Bool? = true, update: Bool? = false) -> Settings {
    var s = Settings()
    s.usageCounts = counts
    s.updateCheck = update
    return s
  }

  @Test func pingHasExactlyTheServerKeys() throws {
    var st = UsageState()
    st.firstRunAt = Self.date("2026-10-20T10:00:00Z").timeIntervalSince1970 * 1000
    let p = try must(Usage.ping(state: st, now: Self.date("2026-10-25T09:00:00Z"), app: "0.1.0", os: 26, lang: .zhHans, answered7d: 7))
    let enc = JSONEncoder()
    enc.outputFormatting = .sortedKeys
    let json = String(decoding: try enc.encode(p), as: UTF8.self)
    #expect(json == #"{"age":"2-7d","app":"0.1.0","arch":"\#(Usage.arch)","build":"direct","cohort":"2026-10","day":"2026-10-25","first":true,"lang":"zh-Hans","newMonth":true,"newWeek":true,"os":"26","use7d":"6-20","v":1}"#)
  }

  @Test func buckets() {
    #expect([0, 1, 2, 7, 8, 30, 31, 90, 91, 365, 366].map { Usage.ageBucket(days: $0) }
      == ["0-1d", "0-1d", "2-7d", "2-7d", "8-30d", "8-30d", "31-90d", "31-90d", "91-365d", "91-365d", "1y+"])
    #expect([0, 1, 5, 6, 20, 21, 500].map(Usage.use7dBucket) == ["0", "1-5", "1-5", "6-20", "6-20", "21+", "21+"])
  }

  @Test func weekAndMonthInUTC() {
    // 2026-12-31 is a Thursday of ISO week 53; 2027-01-01 (Friday) is still in it.
    #expect(Usage.isoWeek(Self.date("2026-12-31T23:59:59Z")) == "2026-W53")
    #expect(Usage.isoWeek(Self.date("2027-01-01T00:00:00Z")) == "2026-W53")
    #expect(Usage.isoWeek(Self.date("2027-01-04T00:00:00Z")) == "2027-W01")
    #expect(Usage.month(Self.date("2026-10-31T23:59:59Z")) == "2026-10")
    #expect(Usage.day(Self.date("2026-11-01T00:00:00Z")) == "2026-11-01")
  }

  @Test func answeredCountsTheLastSevenDays() {
    let now = Self.date("2026-10-25T12:00:00Z")
    func r(_ daysAgo: Double, _ outcome: String) -> ActivityRecord {
      ActivityRecord(at: (now.timeIntervalSince1970 - daysAgo * 86_400) * 1000, durationMs: 1, tokenId: "t", label: "l", mode: "single", outcome: outcome)
    }
    #expect(Usage.answered([r(1, "answered"), r(6.9, "answered"), r(7.1, "answered"), r(2, "timeout")], now: now) == 2)
  }

  @Test func flagsFollowTheLastAcceptedPing() async throws {
    let t = RecordingTransport()
    let clock = Clock("2026-10-25T09:00:00Z") // Sunday
    let (c, _) = try client(t, clock)
    await c.tick(settings: on(), app: "0.1.0", lang: .en) { 0 }
    await c.tick(settings: on(), app: "0.1.0", lang: .en) { 0 } // same day: nothing
    #expect(t.requests.count == 1)
    clock.now = Self.date("2026-10-26T09:00:00Z") // Monday: new week, same month
    await c.tick(settings: on(), app: "0.1.0", lang: .en) { 0 }
    clock.now = Self.date("2026-10-27T09:00:00Z")
    await c.tick(settings: on(), app: "0.1.0", lang: .en) { 0 }
    clock.now = Self.date("2026-11-01T09:00:00Z")
    await c.tick(settings: on(), app: "0.1.0", lang: .en) { 0 }
    let pings = try t.requests.map { try JSONDecoder().decode(UsagePing.self, from: try must($0.httpBody)) }
    #expect(pings.map(\.first) == [true, false, false, false])
    #expect(pings.map(\.newWeek) == [true, true, false, false])
    #expect(pings.map(\.newMonth) == [true, false, false, true])
    #expect(t.requests.allSatisfy { $0.url?.absoluteString == "https://homebot.fun/api/v1/ping" && $0.httpMethod == "POST" })
  }

  @Test func failedPingIsRetriedAndNotMarked() async throws {
    var fail = true
    let t = RecordingTransport(status: { _ in fail ? 500 : 204 })
    let (c, _) = try client(t, Clock("2026-10-25T09:00:00Z"))
    await c.tick(settings: on(), app: "0.1.0", lang: .en) { 0 }
    #expect(await c.state().lastDay == nil)
    fail = false
    await c.tick(settings: on(), app: "0.1.0", lang: .en) { 0 }
    #expect(t.requests.count == 2)
    #expect(await c.state().lastDay == "2026-10-25")
    #expect(await c.state().lastPing?.first == true)
  }

  @Test(arguments: [nil, false] as [Bool?])
  func nothingSentWithoutConsent(_ counts: Bool?) async throws {
    let t = RecordingTransport()
    let (c, home) = try client(t, Clock("2026-10-25T09:00:00Z"))
    let probe = Clock("2026-10-25T09:00:00Z")
    await c.tick(settings: on(counts), app: "0.1.0", lang: .en) { probe.now = .distantPast; return 0 }
    #expect(t.requests.isEmpty)
    #expect(probe.now != .distantPast) // the activity count was never read
    // The first-run time is kept locally so the cohort is right if counts are turned on later.
    #expect(await c.state().firstRunAt != nil)
    #expect(FileManager.default.fileExists(atPath: home.usage.path))
  }

  @Test(arguments: ["DO_NOT_TRACK", "HOMEBOT_NO_USAGE"])
  func environmentForcesOff(_ name: String) async throws {
    let t = RecordingTransport()
    let (c, _) = try client(t, Clock("2026-10-25T09:00:00Z"), env: [name: "1"])
    await c.tick(settings: on(), app: "0.1.0", lang: .en) { 0 }
    #expect(t.requests.isEmpty)
    #expect(await !c.countsOn(on()))
  }

  @Test func updateCheckOncePerDay() async throws {
    let t = RecordingTransport(body: Data(#"{"version":"0.2.0","url":"https://homebot.fun/download/Homebot-0.2.0.zip?from=app","sha256":"ab"}"#.utf8))
    let clock = Clock("2026-10-25T09:00:00Z")
    let (c, _) = try client(t, clock)
    await c.tick(settings: on(false, update: nil), app: "0.1.0", lang: .en) { 0 }
    await c.tick(settings: on(false, update: nil), app: "0.1.0", lang: .en) { 0 }
    #expect(t.requests.count == 1)
    let r = try must(t.requests.first)
    #expect(r.url?.absoluteString == "https://homebot.fun/api/v1/latest" && r.httpMethod == "GET" && r.httpBody == nil)
    #expect(await c.update(current: "0.1.0")?.version == "0.2.0")
    #expect(await c.update(current: "0.2.0") == nil)
    await c.tick(settings: on(false, update: false), app: "0.1.0", lang: .en) { 0 }
    clock.now = Self.date("2026-10-26T09:00:00Z")
    await c.tick(settings: on(false, update: false), app: "0.1.0", lang: .en) { 0 }
    #expect(t.requests.count == 1)
  }

  @Test func versions() {
    #expect(Usage.isNewer("0.10.0", than: "0.9.1"))
    #expect(Usage.isNewer("1.0", than: "0.9.9"))
    #expect(!Usage.isNewer("0.1.0", than: "0.1"))
    #expect(!Usage.isNewer("0.1.0", than: "0.2.0"))
  }

  @Test func subscribeBody() async throws {
    let t = RecordingTransport(status: { _ in 202 })
    let (c, _) = try client(t, Clock("2026-10-25T09:00:00Z"))
    #expect(await c.subscribe(email: "a@example.com", lang: .ja))
    let r = try must(t.requests.first)
    #expect(r.url?.absoluteString == "https://homebot.fun/api/v1/subscribe")
    #expect(String(decoding: try must(r.httpBody), as: UTF8.self) == #"{"email":"a@example.com","lang":"ja","source":"app"}"#)
  }

  @Test func settingsPatchMergesTheNewFields() {
    var a = SettingsPatch()
    a.usageCounts = true
    var b = SettingsPatch()
    b.updateCheck = false
    let s = Settings(a.merged(with: b))
    #expect(s.usageCounts == true && s.updateCheck == false)
    #expect(Settings().usageCounts == nil)
  }
}
