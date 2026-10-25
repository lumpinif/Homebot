// Settings › This Mac: usage counts are off until switched on (or Share on Home's one-time
// prompt after setup), then the ping is sent (kept in
// usage.json, not shown); the update check finds a newer release; Help's sign-up posts once.
import Foundation
import Testing

import HomebotCore
import HomebotGateway
import HomebotTestSupport
@testable import HomebotUI

final class UsageServer: HTTPTransport, @unchecked Sendable {
  var requests: [URLRequest] = []
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let path = request.url?.path ?? ""
    let code = path == "/api/v1/latest" ? 200 : path == "/api/v1/subscribe" ? 202 : 204
    let body = path == "/api/v1/latest" ? Data(#"{"version":"99.0.0","url":"https://homebot.fun/download/Homebot-99.0.0.zip?from=app","sha256":"ab"}"#.utf8) : Data()
    return (body, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
  }
  func paths() -> [String] { requests.compactMap { $0.url?.path } }
}

@MainActor
@Suite(.serialized) struct UsageSettingsTests {
  @Test func offUntilSwitchedOn() async throws {
    let server = UsageServer()
    let m = try await makeModel(FakeGrokBot(), usage: server)
    #expect(!m.snapshot.usageCounts && m.snapshot.updateCheck)
    await m.usageTick()
    #expect(server.paths() == ["/api/v1/latest"])
    #expect(m.update?.version == "99.0.0")
    #expect(await m.usage.state().lastPing == nil)

    await m.setUsageCounts(true)
    #expect(m.snapshot.usageCounts)
    #expect(server.paths() == ["/api/v1/latest", "/api/v1/ping"])
    #expect(await m.usage.state().lastPing?.first == true, "the ping stays in usage.json, not in the UI")

    await m.setUpdateCheck(false)
    #expect(!m.snapshot.updateCheck && m.update == nil)
    await m.shutdown()
  }

  /// A model where Homebot is Ready: a key, a bot and a Shortcut that has answered.
  func readyModel(_ server: UsageServer) async throws -> AppModel {
    let fake = FakeGrokBot()
    fake.addNamed("homebot", sid: "14752726")
    let m = try await makeModel(fake, usage: server)
    _ = await m.saveKey(FakeGrokBot.key)
    #expect(await m.addBySession("14752726", name: "homebot", strict: true))
    let k = m.snapshot.bots[0].key
    #expect(!m.asksUsage, "never during setup")
    let b = try #require(await m.makeShortcut(ShortcutInput(bot: k, url: "http://mac.local:8787"), sign: false))
    let secret = try #require(DevSeed.token(in: try m.builtFile(b.tokenId).file))
    _ = try await m.host.tokens.verify(secret, bot: k)
    try await m.host.tokens.takeOver(b.tokenId)
    await m.refresh()
    #expect(m.setUp)
    return m
  }

  @Test("Home asks once after setup; nothing is sent before an answer or after Not now (DECISIONS item 38)")
  func askedOnceNotNow() async throws {
    let server = UsageServer()
    let m = try await readyModel(server)
    defer { Task { await m.shutdown() } }
    #expect(m.asksUsage && !m.snapshot.usageAsked)
    await m.usageTick()
    #expect(!server.paths().contains("/api/v1/ping"), "no ping before the user answers")
    await m.setUsageCounts(false)
    #expect(!m.asksUsage && m.snapshot.usageAsked && !m.snapshot.usageCounts)
    await m.usageTick()
    #expect(!server.paths().contains("/api/v1/ping"), "none after Not now")
    #expect(await m.usage.state().lastPing == nil)
  }

  @Test func askedOnceShare() async throws {
    let server = UsageServer()
    let m = try await readyModel(server)
    defer { Task { await m.shutdown() } }
    await m.setUsageCounts(true)
    #expect(!m.asksUsage && m.snapshot.usageCounts)
    #expect(server.paths().filter { $0 == "/api/v1/ping" }.count == 1, "Share is the Settings switch")
  }

  @Test func asksOnlyWhenReadyAndUnanswered() {
    var s = Snapshot()
    #expect(!Flow.asksUsage(s, running: true, forcedOff: false), "not set up")
    s = Snapshot(credential: CredentialView(source: .saved, access: .ok), bots: oneBot, tokens: [token("a", state: .active)])
    #expect(Flow.isSetUp(s))
    #expect(Flow.asksUsage(s, running: true, forcedOff: false))
    #expect(!Flow.asksUsage(s, running: false, forcedOff: false), "not while stopped")
    #expect(!Flow.asksUsage(s, running: true, forcedOff: true), "DO_NOT_TRACK")
    s.usageAsked = true
    #expect(!Flow.asksUsage(s, running: true, forcedOff: false), "answered here or in Settings")
  }

  @Test func subscribePostsOnce() async throws {
    let server = UsageServer()
    let m = try await makeModel(FakeGrokBot(), usage: server)
    #expect(await m.subscribe(email: "  a@example.com "))
    #expect(server.paths() == ["/api/v1/subscribe"])
    let body = String(decoding: try #require(server.requests.first?.httpBody), as: UTF8.self)
    #expect(body.contains(#""email":"a@example.com""#) && body.contains(#""source":"app""#))
    await m.shutdown()
  }

  @Test func devRunsReachNoServer() throws {
    var env = AppEnv()
    env.dev = true
    env.home = try shortDir().appendingPathComponent("hb", isDirectory: true)
    let m = try AppModel(env: env)
    #expect(m.usage.transport is OfflineTransport)
  }
}
