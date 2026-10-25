// Settings › This Mac: usage counts are off until switched on, then the ping is sent (kept in
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
