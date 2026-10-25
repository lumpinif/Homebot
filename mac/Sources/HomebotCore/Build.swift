// Shortcut action graphs (DESIGN §7.1, §18.2, §19.1). Pure: plist values in, no I/O. The token
// ends up inside the result, so the serialized file is a secret artifact. Ported from
// src/shortcut/build.ts: same actions, keys, key order and UUID draw order, so for the same inputs
// and UUIDs the XML is byte-for-byte the TypeScript builder's (golden test).
//
// Loop identifiers and keys follow the ScPL action definitions (MIT) and the ShortcutsBench
// parameter extract (Apache-2.0); identifiers only, no code copied.
import Foundation

public struct ShortcutBuilder {
  /// Draws action UUIDs (upper case). Tests pass a counter for golden output.
  var uuid: () -> String

  public init(uuid: @escaping () -> String = { UUID().uuidString.uppercased() }) {
    self.uuid = uuid
  }

  public struct BuildError: Error, CustomStringConvertible, Equatable {
    public let description: String
  }

  /// Steps in a lab run; the gateway ends the run on this step at the latest.
  public static let labSteps = 10

  // MARK: building blocks

  typealias Dict = [(String, PlistValue)]

  static func text(_ s: String) -> PlistValue {
    .dict([("Value", .dict([("string", .string(s))])), ("WFSerializationType", .string("WFTextTokenString"))])
  }

  /// Reference to an earlier action's output inside a text field.
  static func output(_ outUuid: String, _ outName: String) -> PlistValue {
    .dict([
      ("Value", .dict([
        ("string", .string("\u{FFFC}")),
        ("attachmentsByRange", .dict([("{0, 1}", .dict([("OutputUUID", .string(outUuid)), ("OutputName", .string(outName)), ("Type", .string("ActionOutput"))]))])),
      ])),
      ("WFSerializationType", .string("WFTextTokenString")),
    ])
  }

  static func dict(_ items: [(String, PlistValue)]) -> PlistValue {
    .dict([
      ("Value", .dict([("WFDictionaryFieldValueItems", .array(items.map { .dict([("WFItemType", .integer(0)), ("WFKey", text($0.0)), ("WFValue", $0.1)]) }))])),
      ("WFSerializationType", .string("WFDictionaryFieldValue")),
    ])
  }

  static func action(_ id: String, _ params: Dict) -> PlistValue {
    .dict([("WFWorkflowActionIdentifier", .string(id)), ("WFWorkflowActionParameters", .dict(params))])
  }

  static func workflow(_ actions: [PlistValue]) -> PlistValue {
    .dict([
      ("WFWorkflowActions", .array(actions)),
      ("WFWorkflowClientVersion", .string("2607.0.2")),
      ("WFWorkflowMinimumClientVersion", .integer(900)),
      ("WFWorkflowMinimumClientVersionString", .string("900")),
      ("WFWorkflowIcon", .dict([("WFWorkflowIconStartColor", .integer(4_282_601_983)), ("WFWorkflowIconGlyphNumber", .integer(59511))])),
      ("WFWorkflowImportQuestions", .array([])),
      ("WFWorkflowInputContentItemClasses", .array([])),
      ("WFWorkflowOutputContentItemClasses", .array([])),
      ("WFWorkflowTypes", .array([])),
      ("WFWorkflowHasShortcutInputVariables", .bool(false)),
      ("WFWorkflowHasOutputFallback", .bool(false)),
      ("WFQuickActionSurfaces", .array([])),
    ])
  }

  func speak(_ srcUuid: String, _ speakLang: String) -> PlistValue {
    ShortcutBuilder.action("is.workflow.actions.speaktext", [
      ("UUID", .string(uuid())), ("WFText", ShortcutBuilder.output(srcUuid, "Contents of URL")), ("WFSpeakTextWait", .bool(true)), ("WFSpeakTextLanguage", .string(speakLang)),
    ])
  }

  /// The origin of an http(s) URL (the TypeScript `new URL(baseUrl).origin`).
  public static func origin(_ baseUrl: String) throws -> String {
    guard let c = URLComponents(string: baseUrl), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = c.host, !host.isEmpty
    else { throw BuildError(description: "gateway URL must be http(s)") }
    let defaultPort = scheme == "http" ? 80 : 443
    let port = c.port.flatMap { $0 == defaultPort ? nil : $0 }
    let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host.lowercased()
    return "\(scheme)://\(h)\(port.map { ":\($0)" } ?? "")"
  }

  // MARK: Shortcuts

  /// The voice Shortcut for one bot (DESIGN §7.1).
  public func askShortcut(baseUrl: String, botKey: String, token: String, prompt: String, speakLang: String) throws -> PlistValue {
    let origin = try ShortcutBuilder.origin(baseUrl)
    let ask = uuid()
    let dl = uuid()
    return ShortcutBuilder.workflow([
      ShortcutBuilder.action("is.workflow.actions.ask", [("UUID", .string(ask)), ("WFAskActionPrompt", .string(prompt)), ("WFInputType", .string("Text"))]),
      ShortcutBuilder.action("is.workflow.actions.downloadurl", [
        ("UUID", .string(dl)),
        ("WFURL", .string("\(origin)/v1/ask")),
        ("WFHTTPMethod", .string("POST")),
        ("ShowHeaders", .bool(true)),
        ("WFHTTPHeaders", ShortcutBuilder.dict([("X-Homebot-Token", ShortcutBuilder.text(token)), ("Content-Type", ShortcutBuilder.text("application/json"))])),
        ("WFHTTPBodyType", .string("JSON")),
        ("WFJSONValues", ShortcutBuilder.dict([("bot", ShortcutBuilder.text(botKey)), ("text", ShortcutBuilder.output(ask, "Provided Input")), ("v", ShortcutBuilder.text("1"))])),
      ]),
      speak(dl, speakLang),
    ])
  }

  /// Wait-limit probe (DESIGN §7.6): GET /v1/probe-wait, then speak how long it waited.
  public func probeShortcut(baseUrl: String, token: String, speakLang: String) throws -> PlistValue {
    let origin = try ShortcutBuilder.origin(baseUrl)
    let dl = uuid()
    return ShortcutBuilder.workflow([
      ShortcutBuilder.action("is.workflow.actions.downloadurl", [
        ("UUID", .string(dl)), ("WFURL", .string("\(origin)/v1/probe-wait")), ("WFHTTPMethod", .string("GET")), ("ShowHeaders", .bool(true)),
        ("WFHTTPHeaders", ShortcutBuilder.dict([("X-Homebot-Token", ShortcutBuilder.text(token))])),
      ]),
      speak(dl, speakLang),
    ])
  }

  // MARK: loop blocks (DESIGN §18.2, §19.1)

  /// A named variable inside a text field.
  static func varText(_ name: String) -> PlistValue {
    .dict([
      ("Value", .dict([("string", .string("\u{FFFC}")), ("attachmentsByRange", .dict([("{0, 1}", .dict([("Type", .string("Variable")), ("VariableName", .string(name))]))]))])),
      ("WFSerializationType", .string("WFTextTokenString")),
    ])
  }

  /// A named variable read as Text ("Get: Text" in the editor). An If on a plain Dictionary Value
  /// variable offers only "has any value" on iOS/macOS 26, so "is"/"is not" lose their value and
  /// the Shortcut stops with "Please choose a value for each parameter" (DESIGN §18.2).
  static func varInputAsText(_ name: String) -> PlistValue {
    .dict([
      ("Value", .dict([
        ("Aggrandizements", .array([.dict([("CoercionItemClass", .string("WFStringContentItem")), ("Type", .string("WFCoercionVariableAggrandizement"))])])),
        ("Type", .string("Variable")), ("VariableName", .string(name)),
      ])),
      ("WFSerializationType", .string("WFTextTokenAttachment")),
    ])
  }

  /// An earlier action's output as an action's whole input.
  static func outInput(_ outUuid: String, _ outName: String) -> PlistValue {
    .dict([("Value", .dict([("Type", .string("ActionOutput")), ("OutputUUID", .string(outUuid)), ("OutputName", .string(outName))])), ("WFSerializationType", .string("WFTextTokenAttachment"))])
  }

  func setVar(_ name: String, _ input: PlistValue) -> PlistValue {
    ShortcutBuilder.action("is.workflow.actions.setvariable", [("UUID", .string(uuid())), ("WFVariableName", .string(name)), ("WFInput", input)])
  }

  /// Get Dictionary Value `key` from the response of action `dl`, stored in variable `key`.
  func field(_ dl: String, _ key: String) -> [PlistValue] {
    let id = uuid()
    return [
      ShortcutBuilder.action("is.workflow.actions.getvalueforkey", [
        ("UUID", .string(id)), ("WFInput", ShortcutBuilder.outInput(dl, "Contents of URL")), ("WFDictionaryKey", .string(key)), ("WFGetDictionaryValueType", .string("Value")),
      ]),
      setVar(key, ShortcutBuilder.outInput(id, "Dictionary Value")),
    ]
  }

  /// WFCondition codes: 4 "is", 5 "is not". `then`/`otherwise` are built by the caller first,
  /// as in the TypeScript version (their UUIDs come before the group's).
  func ifVar(_ name: String, _ condition: Int64, _ value: String, then: [PlistValue], otherwise: [PlistValue]? = nil) -> [PlistValue] {
    let group = uuid()
    func mode(_ m: Int64, _ extra: Dict = []) -> PlistValue {
      ShortcutBuilder.action("is.workflow.actions.conditional", [("UUID", .string(uuid())), ("GroupingIdentifier", .string(group)), ("WFControlFlowMode", .integer(m))] + extra)
    }
    var out = [mode(0, [
      ("WFCondition", .integer(condition)), ("WFConditionalActionString", .string(value)),
      ("WFInput", .dict([("Type", .string("Variable")), ("Variable", ShortcutBuilder.varInputAsText(name))])),
    ])]
    out += then
    if let otherwise {
      out.append(mode(1))
      out += otherwise
    }
    out.append(mode(2))
    return out
  }

  func repeatCount(_ count: Int, _ body: [PlistValue]) -> [PlistValue] {
    let group = uuid()
    let open = ShortcutBuilder.action("is.workflow.actions.repeat.count", [("UUID", .string(uuid())), ("GroupingIdentifier", .string(group)), ("WFControlFlowMode", .integer(0)), ("WFRepeatCount", .integer(Int64(count)))])
    let close = ShortcutBuilder.action("is.workflow.actions.repeat.count", [("UUID", .string(uuid())), ("GroupingIdentifier", .string(group)), ("WFControlFlowMode", .integer(2))])
    return [open] + body + [close]
  }

  func speakVar(_ name: String, _ speakLang: String) -> PlistValue {
    ShortcutBuilder.action("is.workflow.actions.speaktext", [
      ("UUID", .string(uuid())), ("WFText", ShortcutBuilder.varText(name)), ("WFSpeakTextWait", .bool(true)), ("WFSpeakTextLanguage", .string(speakLang)),
    ])
  }

  /// Ask for Input whose question is variable `prompt`; the answer goes to variable `heard`.
  func askInto(_ prompt: String) -> [PlistValue] {
    let id = uuid()
    return [
      ShortcutBuilder.action("is.workflow.actions.ask", [("UUID", .string(id)), ("WFAskActionPrompt", ShortcutBuilder.varText(prompt)), ("WFInputType", .string("Text"))]),
      setVar("heard", ShortcutBuilder.outInput(id, "Provided Input")),
    ]
  }

  func exit() -> PlistValue {
    ShortcutBuilder.action("is.workflow.actions.exit", [("UUID", .string(uuid()))])
  }

  /// Speak `say` and stop unless the gateway said to keep listening.
  func endUnlessListen(_ speakLang: String) -> [PlistValue] {
    let then = [speakVar("say", speakLang), exit()]
    return ifVar("next", 5, "listen", then: then)
  }

  /// A looping Shortcut: a start POST (step 0), then up to `steps` listen-and-POST steps. Each JSON
  /// response names how to speak `say`: V1 = Speak Text, then Ask for Input with `ask`; V2 = Ask
  /// for Input with `say` as the question. The run ends when `next` is not "listen". `fields` are
  /// sent with every POST (e.g. the bot), `startFields` with step 0.
  func loopShortcut(url: String, token: String, speakLang: String, steps: Int, fields extra: Dict = [], startFields: Dict = []) -> PlistValue {
    func post(_ id: String, _ body: Dict) -> PlistValue {
      ShortcutBuilder.action("is.workflow.actions.downloadurl", [
        ("UUID", .string(id)), ("WFURL", .string(url)), ("WFHTTPMethod", .string("POST")), ("ShowHeaders", .bool(true)),
        ("WFHTTPHeaders", ShortcutBuilder.dict([("X-Homebot-Token", ShortcutBuilder.text(token)), ("Content-Type", ShortcutBuilder.text("application/json"))])),
        ("WFHTTPBodyType", .string("JSON")),
        ("WFJSONValues", ShortcutBuilder.dict(body)),
      ])
    }
    func fields(_ dl: String) -> [PlistValue] { ["say", "ask", "mode", "next"].flatMap { field(dl, $0) } }
    let start = uuid()
    let step = uuid()
    let T = ShortcutBuilder.text
    var actions: [PlistValue] = []
    actions.append(post(start, [("v", T("2"))] + extra + [("step", T("0")), ("run", T("")), ("last", T(String(steps))), ("text", T(""))] + startFields))
    actions += fields(start)
    actions += field(start, "run")
    actions += endUnlessListen(speakLang)
    // The loop body is built before the repeat's own UUIDs are drawn, as in the TypeScript version.
    var body: [PlistValue] = []
    let v2 = askInto("say")
    let v1 = [speakVar("say", speakLang)] + askInto("ask")
    body += ifVar("mode", 4, "v2", then: v2, otherwise: v1)
    body.append(post(step, [("v", T("2"))] + extra + [
      ("run", ShortcutBuilder.varText("run")), ("step", ShortcutBuilder.varText("Repeat Index")), ("last", T(String(steps))), ("text", ShortcutBuilder.varText("heard")),
    ]))
    body += fields(step)
    body += endUnlessListen(speakLang)
    actions += repeatCount(steps, body)
    actions.append(speakVar("say", speakLang))
    return ShortcutBuilder.workflow(actions)
  }

  /// The lab Shortcut (DESIGN §19.1): the loop against /v1/lab.
  public func labShortcut(baseUrl: String, token: String, speakLang: String) throws -> PlistValue {
    loopShortcut(url: "\(try ShortcutBuilder.origin(baseUrl))/v1/lab", token: token, speakLang: speakLang, steps: ShortcutBuilder.labSteps)
  }

  /// The entry Shortcut (DESIGN §20.5): one phrase for a set of bots. The same thin loop as the
  /// conversation Shortcut, without a `bot` field: the gateway's step 0 pins a one-bot set (and
  /// says the bot's name before the question) or speaks the numbered menu, matches the answer,
  /// speaks the choice back, and keeps the run pinned to that bot. The menu lives on the Mac, so
  /// adding a bot to the set needs no new Shortcut. Choosing steps count against the same cap.
  public func entryShortcut(baseUrl: String, token: String, speakLang: String) throws -> PlistValue {
    loopShortcut(url: "\(try ShortcutBuilder.origin(baseUrl))/v1/ask", token: token, speakLang: speakLang, steps: Conversation.steps)
  }

  /// The conversation Shortcut (DESIGN §18.2): the loop against /v1/ask with `v: "2"`. Step 0
  /// sends the Shortcut's own question, which the gateway returns as the first prompt.
  public func conversationShortcut(baseUrl: String, botKey: String, token: String, prompt: String, speakLang: String) throws -> PlistValue {
    loopShortcut(
      url: "\(try ShortcutBuilder.origin(baseUrl))/v1/ask", token: token, speakLang: speakLang, steps: Conversation.steps,
      fields: [("bot", ShortcutBuilder.text(botKey))], startFields: [("prompt", ShortcutBuilder.text(prompt))])
  }
}
