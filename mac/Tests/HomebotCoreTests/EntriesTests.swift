// Ported from test/entries.test.ts: paging to the session's end, and the ownership rules O1–O5.
import Foundation
import Testing

@testable import HomebotCore

/// Fake paged store: entries ordered by updatedSeq, 200 per page, like the real API.
final class PagedStore: @unchecked Sendable {
  let entries: [Entry]
  let pageSize: Int
  private(set) var calls: [String] = []

  init(_ entries: [Entry], pageSize: Int = 200) {
    self.entries = entries
    self.pageSize = pageSize
  }

  func fetch(_ cursor: String) async throws -> Page {
    calls.append(cursor)
    let c = try Seq.parse(cursor)
    let after = Array(try entries.filter { try Seq.parse($0.updatedSeq!) > c }.prefix(pageSize))
    return Page(entries: after, latestUpdatedSeq: after.last?.updatedSeq ?? cursor, turn: Turn(idle: .bool(true)))
  }
}

func mk(_ n: Int) -> [Entry] {
  (0..<n).map { i in Entry(seq: String(i + 1), updatedSeq: String(i + 1), kind: "message", role: "user", text: "m\(i + 1)") }
}

@Suite("Entries: syncToEnd")
struct SyncTests {
  @Test("walks past the first 200-entry page to the real end")
  func pages() async throws {
    let s = PagedStore(mk(450))
    let r = try await syncToEnd(cursor: "-1", fetchPage: s.fetch)
    #expect(r.cursor == "450")
    #expect(r.maxSeq == "450")
    #expect(r.entries.count == 450)
    #expect(s.calls == ["-1", "200", "400", "450"])
  }

  @Test("handles exactly 200 entries and an empty session")
  func edges() async throws {
    let a = try await syncToEnd(cursor: "-1", fetchPage: PagedStore(mk(200)).fetch)
    #expect(a.cursor == "200")
    let b = try await syncToEnd(cursor: "-1", fetchPage: PagedStore([]).fetch)
    #expect(b.cursor == "-1")
    #expect(b.maxSeq == "-1")
  }

  @Test("keeps the cursor on an empty page and resumes from a warm cursor")
  func warm() async throws {
    let s = PagedStore(mk(10))
    let r = try await syncToEnd(cursor: "10", maxSeq: "10", fetchPage: s.fetch)
    #expect(r.cursor == "10")
    #expect(r.maxSeq == "10")
    #expect(s.calls == ["10"])
  }

  @Test("tracks max creation seq even when old entries are re-updated")
  func reupdated() async throws {
    let entries = mk(5) + [Entry(seq: "2", updatedSeq: "6", kind: "send-message")]
    let r = try await syncToEnd(cursor: "5", maxSeq: "5", fetchPage: PagedStore(entries).fetch)
    #expect(r.cursor == "6")
    #expect(r.maxSeq == "5")
  }

  @Test("fails clearly when the history exceeds the page cap")
  func cap() async throws {
    await #expect(throws: HistoryTooLongError.self) {
      try await syncToEnd(cursor: "-1", maxPages: 2, fetchPage: PagedStore(mk(450)).fetch)
    }
  }

  @Test("hands each page's entries over as soon as it arrives (BDK re-review R1)")
  func evidenceSurvivesFailure() async throws {
    let s = PagedStore(mk(450))
    var seen = 0
    await #expect(throws: BdkError.self) {
      try await syncToEnd(cursor: "-1", onEntries: { seen += $0.count }) { c in
        if c == "200" { throw BdkError(message: "down", kind: .upstream, status: 503) }
        return try await s.fetch(c)
      }
    }
    #expect(seen == 200)
  }
}

@Suite("Entries: decideReply (ownership O1–O5)")
struct DecideTests {
  static let id = "a1b2c3d4e5f6"
  static let privateText = "这是给桌面的私密回复"

  func decide(_ seen: [Entry], baseMaxSeq: String = "100", strict: Bool = true) throws -> Decision {
    try decideReply(seen, baseMaxSeq: baseMaxSeq, requestId: Self.id, strictEcho: strict)
  }

  func ours(_ seq: Int) -> Entry {
    Entry(seq: String(seq), kind: "message", role: "user", text: Envelope.build(id: Self.id, text: "几点了", lang: .zhCN, strictEcho: true))
  }
  func desktop(_ seq: Int, _ text: String = "桌面消息") -> Entry { Entry(seq: String(seq), kind: "message", role: "user", text: text) }
  func bot(_ seq: Int, _ text: String) -> Entry { Entry(seq: String(seq), kind: "send-message", text: text) }
  var tag: String { Envelope.echoTag(Self.id) }

  func reason(_ d: Decision) -> Refusal? {
    if case .refuse(let r, _, _) = d { return r }
    return nil
  }
  func text(_ d: Decision) -> String? {
    if case .accept(let t, _, _, _, _) = d { return t }
    return nil
  }

  @Test("accepts the first echoed reply after our message and strips the tag")
  func accept() throws {
    #expect(try decide([ours(101), bot(102, "\(tag) 现在三点。")]) == .accept(text: "现在三点。", userSeq: "101", replySeq: "102"))
  }

  @Test("S25: [end] counts only right after our own tag at the start; it is never left in the text")
  func endMark() throws {
    #expect(try decide([ours(101), bot(102, "\(tag) [end] 好的，回头见。")]) == .accept(text: "[end] 好的，回头见。", userSeq: "101", replySeq: "102", ended: true))
    #expect(try decide([ours(101), bot(102, "  \(tag)[end]")]) == .accept(text: "[end]", userSeq: "101", replySeq: "102", ended: true))
    #expect(try decide([ours(101), bot(102, "\(tag) 好的。")]) == .accept(text: "好的。", userSeq: "101", replySeq: "102"), "missing: not an end")
    #expect(try decide([ours(101), bot(102, "\(tag) 好的 [end] 回头见")]) == .accept(text: "好的 [end] 回头见", userSeq: "101", replySeq: "102"), "mid-text: not an end")
    if case .accept(_, _, _, _, let ended) = try decide([ours(101), bot(102, "[end] \(tag) 好的")]) { #expect(!ended, "before the tag: not an end") } else { Issue.record("not accepted") }
    #expect(!endMarked("[hb:000000000000] [end] bye", tag), "another request's tag")
    #expect(!endMarked("[hb:\(Self.id) [end]", tag), "a broken tag")
    #expect(!endMarked("\(tag) [END]", tag), "exact spelling only")
    #expect(try decide([ours(101), bot(102, "\(tag) [end] bye")], strict: false) == .accept(text: "[end] bye", userSeq: "101", replySeq: "102"), "never without strict echo")
  }

  @Test("waits until our entry and a text reply exist")
  func waiting() throws {
    #expect(try decide([]) == .waiting)
    #expect(try decide([ours(101)]) == .waiting)
    #expect(try decide([ours(101), Entry(seq: "102", kind: "send-message")]) == .waiting) // attachment-only
  }

  @Test("O2: refuses when a desktop message lands between the idle check and our send")
  func o2Before() throws {
    let d = try decide([desktop(101), ours(102), bot(103, Self.privateText), bot(104, "\(tag) 三点")])
    #expect(reason(d) == .O2)
    #expect(text(d) == nil)
  }

  @Test("O2: refuses when a desktop message lands after ours, before the reply")
  func o2After() throws {
    let d = try decide([ours(101), desktop(102), bot(103, "\(tag) \(Self.privateText)")])
    #expect(reason(d) == .O2)
    #expect(!String(describing: d).contains(Self.privateText))
  }

  @Test("O2: a foreign user entry refuses even before our own entry shows up")
  func o2Early() throws {
    #expect(reason(try decide([desktop(101)])) == .O2)
  }

  @Test("O2: unknown kinds with role user count as foreign input")
  func o2Unknown() throws {
    #expect(reason(try decide([ours(101), Entry(seq: "102", kind: "voice-note", role: "user"), bot(103, "\(tag) x")])) == .O2)
  }

  @Test("O3: refuses bot output between the baseline and our message")
  func o3() throws {
    #expect(reason(try decide([bot(101, Self.privateText), ours(102), bot(103, "\(tag) 三点")])) == .O3)
  }

  @Test("O5: strict mode never accepts a reply without the echo tag (it stays unproved); non-strict accepts it")
  func o5() throws {
    let seen = [ours(101), bot(102, Self.privateText)]
    let d = try decide(seen)
    #expect(d == .unproved(interim: 1, userSeq: "101"))
    #expect(!String(describing: d).contains(Self.privateText))
    #expect(text(try decide(seen, strict: false)) == Self.privateText)
  }

  @Test("O5: an echo tag buried deep in the text does not count")
  func o5Deep() throws {
    #expect(try decide([ours(101), bot(102, String(repeating: "x", count: 60) + " " + tag)]) == .unproved(interim: 1, userSeq: "101"))
  }

  @Test("O5: another request's tag is refused at once, in strict and non-strict mode", arguments: [true, false])
  func o5Other(strict: Bool) throws {
    #expect(reason(try decide([ours(101), bot(102, "[hb:ffffffffffff] hi")], strict: strict)) == .O5)
    // Also after an interim delivery, and even when our own tagged reply is in the same observation.
    #expect(reason(try decide([ours(101), bot(102, "正在查。"), bot(103, "[hb:ffffffffffff] hi")], strict: strict)) == .O5)
    #expect(reason(try decide([ours(101), bot(102, "\(tag) 好"), bot(103, "[hb:ffffffffffff] \(Self.privateText)")], strict: strict)) == .O5)
    // In any version of a delivery.
    #expect(reason(try decide([ours(101), bot(102, "[hb:ffffffffffff] x"), bot(102, "\(tag) 好")], strict: strict)) == .O5)
  }

  @Test("interim: untagged deliveries before the tagged reply are skipped and counted, never spoken")
  func interim() throws {
    #expect(try decide([ours(101), bot(102, "正在查你最新的 Gmail。")]) == .unproved(interim: 1, userSeq: "101"))
    let d = try decide([ours(101), bot(102, "正在查你最新的 Gmail。"), bot(103, "还在查。"), bot(104, "\(tag) 你最新一封邮件来自 Vercel。")])
    #expect(d == .accept(text: "你最新一封邮件来自 Vercel。", userSeq: "101", replySeq: "104", interim: 2))
    // Attachment-only sends are neither interim nor the answer.
    #expect(try decide([ours(101), Entry(seq: "102", kind: "send-message"), bot(103, "\(tag) 好")]) == .accept(text: "好", userSeq: "101", replySeq: "103"))
  }

  @Test("Codex review: another request's tag past the head window still refuses, in strict and non-strict mode", arguments: [true, false])
  func foreignTagDeep(strict: Bool) throws {
    let deep = String(repeating: " ", count: 41) + "[hb:ffffffffffff] \(Self.privateText)"
    #expect(reason(try decide([ours(101), bot(102, deep)], strict: strict)) == .O5)
    #expect(reason(try decide([ours(101), bot(102, deep), bot(103, "\(tag) 好")], strict: strict)) == .O5)
    // Our own tag first: later fragments are only stripped before speech.
    #expect(text(try decide([ours(101), bot(102, "\(tag) 好 \(String(repeating: "x", count: 50)) [hb:ffffffffffff]")], strict: strict)) != nil)
  }

  @Test("Codex review: a lost tag stays evidence even when a later version restores it, or another delivery is tagged")
  func tagLossKept() throws {
    #expect(reason(try decide([ours(101), bot(102, "正在查。"), bot(103, "\(tag) OWNED"), bot(103, Self.privateText), bot(103, "\(tag) OWNED")])) == .O5)
    #expect(reason(try decide([ours(101), bot(102, "正在查。"), bot(103, "\(tag) A"), bot(103, Self.privateText), bot(102, "\(tag) B")])) == .O5)
    // A textless re-update is not a loss.
    #expect(text(try decide([ours(101), bot(102, "\(tag) 第一版"), bot(102, ""), bot(102, "\(tag) 第二版")])) == "第二版")
  }

  @Test("interim: a tagged reply followed by untagged output is answered with the tagged text only")
  func taggedThenUntagged() throws {
    let d = try decide([ours(101), bot(102, "\(tag) OWNED"), bot(103, Self.privateText)])
    #expect(d == .accept(text: "OWNED", userSeq: "101", replySeq: "102", interim: 0))
  }

  @Test("interim: foreign input or earlier foreign output still refuses (O2/O3)")
  func interimForeign() throws {
    #expect(reason(try decide([ours(101), bot(102, "正在查。"), desktop(103), bot(104, "\(tag) 好")])) == .O2)
    #expect(reason(try decide([ours(101), bot(102, "正在查。"), desktop(103)])) == .O2)
    #expect(reason(try decide([bot(101, Self.privateText), ours(102), bot(103, "正在查。"), bot(104, "\(tag) 好")])) == .O3)
  }

  @Test("interim: an untagged delivery later re-updated to carry our tag is the answer")
  func interimReupdated() throws {
    #expect(try decide([ours(101), bot(102, "正在查。"), bot(102, "\(tag) 查到了")]) == .accept(text: "查到了", userSeq: "101", replySeq: "102", interim: 0))
  }

  @Test("ignores re-updated old entries at or below the baseline")
  func baseline() throws {
    let d = try decide([desktop(50), bot(99, Self.privateText), ours(101), bot(102, "\(tag) 好")])
    #expect(text(d) == "好")
  }

  @Test("answer text comes from the latest non-empty version")
  func latestVersion() throws {
    #expect(text(try decide([ours(101), bot(102, ""), bot(102, "\(tag) 完整回答")])) == "完整回答")
    // A later textless re-update does not hide the answer.
    #expect(text(try decide([ours(101), bot(102, "\(tag) 第一版"), bot(102, "")])) == "第一版")
  }

  @Test("BDK review B1: an untagged re-update of the accepted reply is refused, not spoken")
  func b1() throws {
    let d = try decide([ours(101), bot(102, "\(tag) OWNED"), bot(102, Self.privateText)])
    #expect(reason(d) == .O5)
    #expect(!String(describing: d).contains(Self.privateText))
  }

  @Test("BDK review B2: only the first proved delivery is the answer; later untagged output is not")
  func b2() throws {
    #expect(text(try decide([ours(101), bot(102, "\(tag) OWNED"), bot(103, Self.privateText)])) == "OWNED")
  }

  @Test("B4: a textless re-update never erases foreign-output evidence (O3)")
  func b4Output() throws {
    let seen = [bot(101, Self.privateText), ours(102), bot(103, "\(tag) \(Self.privateText)"), Entry(seq: "101", kind: "send-message")]
    let d = try decide(seen)
    #expect(reason(d) == .O3)
    #expect(!String(describing: d).contains(Self.privateText))
  }

  @Test("B4: foreign output already textless when first seen is still foreign output (O3)")
  func b4Textless() throws {
    #expect(reason(try decide([Entry(seq: "101", kind: "send-message"), ours(102), bot(103, "\(tag) 好")])) == .O3)
  }

  @Test("B4: a re-update that drops role:user never erases foreign-input evidence (O2)")
  func b4Role() throws {
    #expect(reason(try decide([desktop(101), ours(102), bot(103, "\(tag) 好"), Entry(seq: "101", kind: "message")])) == .O2)
  }

  @Test("compares seqs numerically, not as strings")
  func numeric() throws {
    #expect(reason(try decide([ours(1000), bot(999, Self.privateText)], baseMaxSeq: "998")) == .O3)
  }

  @Test("seqs beyond 64 bits compare exactly; a malformed seq throws")
  func bigSeq() throws {
    let big = "18446744073709551617" // 2^64 + 1
    #expect(try Seq.parse(big) > (try Seq.parse("18446744073709551616")))
    #expect(throws: SeqError.self) { try Seq.parse("1e3") }
    #expect(try Seq.parse("007") == (try Seq.parse("7")))
    // Deviation: JavaScript's BigInt("") is 0; an empty seq is malformed here.
    #expect(throws: SeqError.self) { try Seq.parse("") }
  }
}
