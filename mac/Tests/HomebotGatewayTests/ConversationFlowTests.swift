// The one-bot conversation Shortcut end to end, offline (S25): the file Homebot builds is played
// by ShortcutRunner against the real gateway and the fake Grok Bot. Felix's case: an English
// Shortcut, and the user says they are done in Chinese, or the bot decides the user is done.
import Foundation
import Testing

@testable import HomebotCore
@testable import HomebotGateway
import HomebotTestSupport

extension HostHarness {
  /// Build the one-bot conversation Shortcut with the app's own builder, then play it.
  func conversation(_ bot: Bot, siriLang: String = "en-US", answers: [String]) async throws -> Exchange {
    let s = try await stores()
    let profile = try Profile.make(botName: bot.name, siriLang: siriLang)
    let made = try await ShortcutMaker.make(tokens: s.tokens, lifecycle: s.lifecycle, bots: [bot], profile: profile, baseUrl: "http://felix-mac.local:8787", kind: .conversation)
    let workflow = try ShortcutRunner.load(made.file)
    return Exchange(made: made, workflow: workflow, runner: try await play(workflow, answers: answers))
  }
}

@Suite("Conversation Shortcut, played offline (S25)", .serialized)
struct ConversationFlowTests {
  let en = Messages.of(.en)

  @Test("an English Shortcut ends on a whole Chinese end phrase; nothing reaches the bot", arguments: ["没有了", "结束", "不用了。"])
  func endPhrase(said: String) async throws {
    let h = try await HostHarness.start(bots: [chaiEn])
    h.fake.autoReply(chaiEn.sessionId, text: "I am Chai.", reportsBusy: false)
    let x = try await h.conversation(chaiEn, answers: ["Who are you?", said])
    #expect(x.siri == ["What would you like to ask Grok Bot?", "I am Chai.", en.more, en.goodbye])
    #expect(h.fake.posts.count == 1, "only the real question was sent")
    await h.stop()
  }

  @Test("a sentence that contains an end word is a question")
  func endWordInSentence() async throws {
    let h = try await HostHarness.start(bots: [chaiEn])
    h.fake.autoReply(chaiEn.sessionId, text: "Write the last task down.", reportsBusy: false)
    let x = try await h.conversation(chaiEn, answers: ["How do I end this project?", "stop"])
    #expect(x.siri == ["What would you like to ask Grok Bot?", "Write the last task down.", en.more, en.goodbye])
    #expect(h.fake.posts.count == 1)
    await h.stop()
  }

  @Test("the bot's end mark stops the loop after its goodbye; the mark is never spoken")
  func botEnds() async throws {
    let h = try await HostHarness.start(bots: [chaiEn])
    h.fake.autoReply(chaiEn.sessionId, text: "[end] Okay, talk soon.", reportsBusy: false)
    let x = try await h.conversation(chaiEn, answers: ["Let's leave it there for today"])
    #expect(x.siri == ["What would you like to ask Grok Bot?", "Okay, talk soon."], "no \"Anything else?\" after the goodbye")
    #expect(x.runner.requests.count == 2)
    await h.stop()
  }
}
