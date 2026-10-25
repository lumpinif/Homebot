// S16: the gateway notes where a voice token's answer was spoken (this Mac or another device),
// for the Install page's "Answered on this Mac" and "Answered from your iPhone".
import Foundation
import Testing

@testable import HomebotCore
@testable import HomebotGateway
import HomebotTestSupport

@Suite("Where an answer was spoken")
struct AnsweredFromTests {
  @Test("loopback and the Mac's own address are this Mac; another address is another device")
  func thisMac() {
    #expect(VoiceResponder.isThisMac(remote: "127.0.0.1", local: "127.0.0.1"))
    #expect(VoiceResponder.isThisMac(remote: "::1", local: "::1"))
    #expect(VoiceResponder.isThisMac(remote: "::ffff:127.0.0.1", local: "192.168.1.5"))
    #expect(VoiceResponder.isThisMac(remote: "192.168.1.5", local: "192.168.1.5"))
    #expect(VoiceResponder.isThisMac(remote: "fe80::1%en0", local: "fe80::1%en0"))
    #expect(!VoiceResponder.isThisMac(remote: "192.168.1.20", local: "192.168.1.5"))
    #expect(!VoiceResponder.isThisMac(remote: nil, local: "192.168.1.5"))
  }

  @Test("an answered request over loopback is noted as here; a refused one is not noted")
  func notedOverHTTP() async throws {
    let notes = Box<[String]>([])
    let v = try await Voice.start(noteAnswer: { id, here in notes.mutate { $0.append("\(id):\(here)") } })
    let r = await RawHTTP.post(port: v.port, ["text": "hi"])
    #expect(r.status == 200)
    #expect(notes.value == ["aaaaaaaaaaaa:true"])
    await v.stop()

    let refused = Box<[String]>([])
    let w = try await Voice.start(ask: { _ in AskResult(text: "busy", outcome: "busy") }, noteAnswer: { id, here in refused.mutate { $0.append("\(id):\(here)") } })
    _ = await RawHTTP.post(port: w.port, ["text": "hi"])
    #expect(refused.value.isEmpty)
    await w.stop()
  }

  @Test("the API passes the request's origin through: another device is noted as elsewhere")
  func elsewhere() async throws {
    let notes = Box<[Bool]>([])
    let api = VoiceAPI(VoiceDeps(admit: { _, _, _, _ in .ok(record(), bot: chaiGrant) }, noteAnswer: { _, here in notes.mutate { $0.append(here) } },
                                 ask: { _ in AskResult(text: "ok", outcome: "answered") }))
    let r = await api.handle(VoiceRequest(method: "POST", target: "/v1/ask", token: "t", here: false) { _ in Data(#"{"text":"hi"}"#.utf8) })
    #expect(r.status == 200)
    #expect(notes.value == [false])
  }
}
