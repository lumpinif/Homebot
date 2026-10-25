// The HTTP Grok Bot client against the in-process fake (the TypeScript version exercised it
// through test/ask.test.ts and test/setup.test.ts; those flows move to S2, the client contract is
// checked here), and add-by-exact-name from test/setup.test.ts (Q-ADD).
import Foundation
import Testing

@testable import HomebotCore

@Suite("Grok Bot client")
struct BdkClientTests {
  @Test("requests carry the bearer key, JSON, the client type, and encoded paths")
  func requestShape() async throws {
    let fake = FakeGrokBot()
    let c = fake.client()
    _ = try await c.getEntries(sessionId: "42", afterUpdatedSeq: "-1")
    _ = try await c.sendMessage(sessionId: "42", messageId: "abc", text: "你好 & <x>")
    let reqs = fake.requests
    #expect(reqs.count == 2)
    #expect(reqs.allSatisfy { $0.auth == "Bearer \(FakeGrokBot.key)" && $0.client == "agent-serve" && $0.contentType == "application/json" })
    #expect(reqs[0].method == "GET" && reqs[0].path == "/v0/grokbot/sessions/42/entries" && reqs[0].query == "afterUpdatedSeq=-1")
    #expect(reqs[1].method == "POST" && reqs[1].path == "/v0/grokbot/sessions/42/messages")
    #expect(reqs[1].body == ["messageId": "abc", "text": "你好 & <x>"])
    #expect(fake.posts == [FakeGrokBot.Post(sid: "42", messageId: "abc", text: "你好 & <x>")])
    #expect(HTTPBdkClient.component("a/b?c") == "a%2Fb%3Fc")
  }

  @Test("pages decode with seqs as strings, the turn flags and a delivery value")
  func decode() async throws {
    let fake = FakeGrokBot()
    fake.add("42", kind: "message", role: "user", text: "q")
    fake.add("42", kind: "send-message", text: "a")
    let p = try await fake.client().getEntries(sessionId: "42", afterUpdatedSeq: "-1")
    #expect(p.entries.map(\.seq) == ["1001", "1002"])
    #expect(p.entries[0].role == "user")
    #expect(p.latestUpdatedSeq == "1002")
    #expect(p.turn == .idleNow)
    let s = try await fake.client().sendMessage(sessionId: "42", messageId: "m1", text: "x")
    #expect(s.delivery == "accepted_temporal")
    #expect(try await fake.client().sendMessage(sessionId: "42", messageId: "m1", text: "x").delivery == "duplicate", "a reused messageId is not sent twice")
    fake.delivery = nil
    #expect(try await fake.client().sendMessage(sessionId: "42", messageId: "m2", text: "x").delivery == nil)
  }

  @Test("status codes map to error kinds; messages never carry the key, a body or a query")
  func errors() async throws {
    let fake = FakeGrokBot()
    let wrong = await errorText { _ = try await fake.client(key: "wrong-key-xyz").getEntries(sessionId: "42", afterUpdatedSeq: "secretseq") }
    #expect(wrong == "BDK GET /42/entries -> 401")
    for (status, kind) in [(401, BdkError.Kind.auth), (403, .auth), (429, .upstream), (500, .upstream), (503, .upstream), (404, .request), (400, .request)] {
      fake.intercept = { _, _, _, _ in .status(status) }
      do {
        _ = try await fake.client().sendMessage(sessionId: "42", messageId: "m", text: "t")
        Issue.record("expected an error for \(status)")
      } catch let e as BdkError {
        #expect(e.kind == kind && e.status == status, "\(status)")
        #expect(!e.description.contains(FakeGrokBot.key))
      }
    }
    fake.intercept = { _, _, _, _ in .destroy }
    let net = await errorText { _ = try await fake.client().getEntries(sessionId: "42", afterUpdatedSeq: "-1") }
    #expect(net == "BDK GET /42/entries failed: other")
    fake.intercept = { _, _, _, _ in .body("<html>dummy-secret</html>") }
    do {
      _ = try await fake.client().getEntries(sessionId: "42", afterUpdatedSeq: "-1")
      Issue.record("expected an error")
    } catch let e as BdkError {
      #expect(e.kind == .upstream && !e.description.contains("dummy"))
    }
  }

  @Test("a call that takes too long fails as a network error")
  func timeout() async throws {
    let fake = FakeGrokBot()
    fake.intercept = { _, _, _, _ in
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      return nil
    }
    let start = Date()
    let e = await errorText { _ = try await fake.client(callTimeoutMs: 50).getEntries(sessionId: "42", afterUpdatedSeq: "-1") }
    #expect(e == "BDK GET /42/entries failed: TimeoutError")
    #expect(Date().timeIntervalSince(start) < 1.5)
  }

  @Test("the time limit holds even for a transport that ignores cancellation (Codex S1 review 10)")
  func hardTimeout() async throws {
    struct Stubborn: HTTPTransport {
      func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
          DispatchQueue.global().asyncAfter(deadline: .now() + 2) { c.resume() }
        }
        throw URLError(.cannotConnectToHost)
      }
    }
    let start = Date()
    let e = await errorText { _ = try await HTTPBdkClient(key: "k", baseURL: FakeGrokBot.baseURL, transport: Stubborn(), callTimeoutMs: 50).getEntries(sessionId: "1", afterUpdatedSeq: "-1") }
    #expect(e == "BDK GET /1/entries failed: TimeoutError")
    #expect(Date().timeIntervalSince(start) < 1)
  }

  @Test("cancelling the caller cancels the call")
  func cancellation() async throws {
    let fake = FakeGrokBot()
    fake.intercept = { _, _, _, _ in
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      return nil
    }
    let t = Task { try await fake.client().getEntries(sessionId: "42", afterUpdatedSeq: "-1") }
    try await Task.sleep(nanoseconds: 20_000_000)
    t.cancel()
    await #expect(throws: CancellationError.self) { _ = try await t.value }
  }

  @Test("autoReply answers with the echo tag, like the real bot when strict")
  func autoReply() async throws {
    let fake = FakeGrokBot()
    fake.autoReply("42", ms: 5, text: "现在三点。")
    let id = "a1b2c3d4e5f6"
    _ = try await fake.client().sendMessage(sessionId: "42", messageId: id, text: Envelope.build(id: id, text: "几点了", lang: .zhCN, strictEcho: true))
    var seen: [Entry] = []
    for _ in 0..<200 {
      seen = try await fake.client().getEntries(sessionId: "42", afterUpdatedSeq: "-1").entries
      if seen.count == 2 { break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(try decideReply(seen, baseMaxSeq: "1000", requestId: id, strictEcho: true) == .accept(text: "现在三点。", userSeq: "1001", replySeq: "1002"))
  }
}

@Suite("Add a bot by exact name (Q-ADD)")
struct ResolveByNameTests {
  @Test("an existing bot resolves to its session; a just-created one is detected")
  func resolve() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("拆解师", sid: "14752726")
    fake.add("14752726", kind: "send-message", text: "old")
    let found = try await Bots.resolveByName(fake.client(), name: "拆解师")
    #expect(found.sessionId == "14752726" && !found.justCreated)
    let typo = try await Bots.resolveByName(fake.client(), name: "拆解狮")
    #expect(typo.justCreated, "an empty session created moments ago was created by this call")
    #expect(fake.created == ["拆解狮"])
  }

  @Test("an empty bot created long ago is not 'just created'")
  func oldEmpty() async throws {
    let fake = FakeGrokBot()
    fake.addNamed("Empty", sid: "7")
    #expect(try await Bots.resolveByName(fake.client(), name: "Empty").justCreated == false)
  }

  @Test("a non-numeric id is refused")
  func badId() async throws {
    let fake = FakeGrokBot()
    fake.intercept = { _, what, _, _ in what == "sessions" ? .body(#"{"id":"abc","latestUpdatedSeq":"-1"}"#) : nil }
    await #expect(throws: BotSetupError.self) { _ = try await Bots.resolveByName(fake.client(), name: "x") }
  }
}
