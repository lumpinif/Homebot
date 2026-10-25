// A small interpreter for the Shortcut files Homebot builds, so a test can "say" things to a
// Shortcut and hear what Siri would say back, offline. It runs exactly the actions the builder
// emits (Ask for Input, Get Contents of URL, Get Dictionary Value, Set Variable, If/Otherwise,
// Repeat, Speak Text, Stop This Shortcut) the way the Shortcuts app documents them; it is not
// Apple's engine. What it proves: the graph's wiring (which output feeds which field, which branch
// speaks, when the loop stops) against the real gateway. What it cannot prove: Siri's timing,
// transcription, or how a HomePod plays an Ask for Input prompt (DESIGN §19, S6).
import Foundation
import HomebotCore

public struct ShortcutRunner {
  public enum Line: Sendable, Equatable, CustomStringConvertible {
    /// Siri asks (Ask for Input) and listens.
    case asks(String)
    /// The user's answer to the last question ("" for silence).
    case user(String)
    /// Siri speaks (Speak Text), in this voice.
    case speaks(String, lang: String)

    public var description: String {
      switch self {
      case .asks(let s): "Siri? \(s)"
      case .user(let s): "User: \(s)"
      case .speaks(let s, _): "Siri: \(s)"
      }
    }
  }

  public struct Request: Sendable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var json: [String: String]
  }

  public struct Failure: Error, CustomStringConvertible {
    public let description: String
  }

  /// Sends one Get Contents of URL request; returns the response body.
  public typealias HTTP = @Sendable (Request) async -> String

  let actions: [PlistValue]
  public private(set) var transcript: [Line] = []
  public private(set) var requests: [Request] = []
  var outputs: [String: String] = [:]
  var vars: [String: String] = [:]
  var answers: [String]
  var stopped = false
  /// Actions run, to catch a graph that never ends.
  var budget = 2000

  /// `answers`: what the user says at each Ask for Input, in order. Running out is a test failure.
  public init(_ workflow: PlistValue, answers: [String]) throws {
    guard let a = workflow["WFWorkflowActions"]?.arrayValue else { throw Failure(description: "no WFWorkflowActions") }
    actions = a
    self.answers = answers
  }

  /// A Shortcut file (XML or binary plist) as a value the runner reads.
  public static func load(_ file: URL) throws -> PlistValue {
    let data = try Data(contentsOf: file)
    return value(try PropertyListSerialization.propertyList(from: data, format: nil))
  }

  static func value(_ any: Any) -> PlistValue {
    switch any {
    case let s as String: return .string(s)
    case let n as NSNumber:
      return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .integer(n.int64Value)
    case let a as [Any]: return .array(a.map(value))
    case let d as [String: Any]: return .dict(d.keys.sorted().map { ($0, value(d[$0]!)) })
    default: return .string("\(any)")
    }
  }

  /// Run the whole Shortcut. Unused answers are left in `remaining`.
  public mutating func run(_ http: HTTP) async throws {
    try await block(0, actions.count, http)
  }

  public var remaining: [String] { answers }

  // MARK: actions

  static func id(_ a: PlistValue) -> String { a["WFWorkflowActionIdentifier"]?.stringValue ?? "" }
  static func params(_ a: PlistValue) -> PlistValue { a["WFWorkflowActionParameters"] ?? .dict([]) }

  /// The index of the action that closes (mode 2) or splits (mode 1) the group opened at `start`.
  func find(_ start: Int, _ end: Int, mode: Int64) -> Int? {
    guard let group = ShortcutRunner.params(actions[start])["GroupingIdentifier"]?.stringValue else { return nil }
    return (start + 1..<end).first { i in
      let p = ShortcutRunner.params(actions[i])
      return p["GroupingIdentifier"]?.stringValue == group && p["WFControlFlowMode"] == .integer(mode)
    }
  }

  mutating func block(_ from: Int, _ to: Int, _ http: HTTP) async throws {
    var i = from
    while i < to && !stopped {
      budget -= 1
      if budget < 0 { throw Failure(description: "the Shortcut did not end") }
      let a = actions[i]
      let p = ShortcutRunner.params(a)
      let uuid = p["UUID"]?.stringValue ?? ""
      switch ShortcutRunner.id(a) {
      case "is.workflow.actions.ask":
        let prompt = text(p["WFAskActionPrompt"])
        transcript.append(.asks(prompt))
        guard !answers.isEmpty else { throw Failure(description: "Siri asked \"\(prompt)\" but the script has no more answers") }
        let heard = answers.removeFirst()
        transcript.append(.user(heard))
        outputs[uuid] = heard
      case "is.workflow.actions.downloadurl":
        // Only what the builder emits: a JSON body of text fields, or a GET with no body.
        if p["WFJSONValues"] != nil && p["WFHTTPBodyType"]?.stringValue != "JSON" { throw Failure(description: "a JSON body without WFHTTPBodyType JSON at \(i)") }
        let r = Request(url: text(p["WFURL"]), method: p["WFHTTPMethod"]?.stringValue ?? "GET", headers: fields(p["WFHTTPHeaders"]), json: fields(p["WFJSONValues"]))
        requests.append(r)
        outputs[uuid] = await http(r)
      case "is.workflow.actions.getvalueforkey":
        let input = attachment(p["WFInput"])
        let key = p["WFDictionaryKey"]?.stringValue ?? ""
        // The gateway's contract: every v2 response is a JSON object with every field (§18.2).
        // A missing field is a failure here, not "", since Shortcuts' handling of it is not known.
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any] else { throw Failure(description: "not a JSON object: \(input.prefix(80))") }
        guard let v = obj[key] as? String else { throw Failure(description: "no text field \"\(key)\" in the response") }
        outputs[uuid] = v
      case "is.workflow.actions.setvariable":
        vars[p["WFVariableName"]?.stringValue ?? ""] = attachment(p["WFInput"])
      case "is.workflow.actions.speaktext":
        transcript.append(.speaks(text(p["WFText"]), lang: p["WFSpeakTextLanguage"]?.stringValue ?? ""))
      case "is.workflow.actions.exit":
        stopped = true
      case "is.workflow.actions.conditional":
        guard p["WFControlFlowMode"] == .integer(0), let close = find(i, to, mode: 2) else { throw Failure(description: "unbalanced If at \(i)") }
        let otherwise = find(i, close, mode: 1)
        guard let ref = p["WFInput"]?["Variable"], let input = value(ref) else { throw Failure(description: "If on a variable that was never set, at \(i)") }
        let value = p["WFConditionalActionString"]?.stringValue ?? ""
        let holds: Bool
        switch p["WFCondition"] {
        case .integer(4)?: holds = input == value
        case .integer(5)?: holds = input != value
        default: throw Failure(description: "unknown condition at \(i)")
        }
        if holds { try await block(i + 1, otherwise ?? close, http) } else if let otherwise { try await block(otherwise + 1, close, http) }
        i = close
      case "is.workflow.actions.repeat.count":
        guard p["WFControlFlowMode"] == .integer(0), let close = find(i, to, mode: 2), case .integer(let n)? = p["WFRepeatCount"] else { throw Failure(description: "unbalanced Repeat at \(i)") }
        for k in 1...max(Int(n), 1) where !stopped {
          vars["Repeat Index"] = "\(k)"
          try await block(i + 1, close, http)
        }
        i = close
      default:
        throw Failure(description: "action the runner does not know: \(ShortcutRunner.id(a))")
      }
      i += 1
    }
  }

  // MARK: values

  /// A text field: plain text, or WFTextTokenString with one attachment per U+FFFC.
  func text(_ v: PlistValue?) -> String {
    guard let v else { return "" }
    if let s = v.stringValue { return s }
    guard let value = v["Value"], let s = value["string"]?.stringValue else { return attachment(v) }
    guard case .dict(let ranges)? = value["attachmentsByRange"] else { return s }
    var out = s
    for (_, att) in ranges {
      if let r = out.range(of: "\u{FFFC}") { out.replaceSubrange(r, with: resolve(att)) }
    }
    return out
  }

  /// A whole-input attachment (WFTextTokenAttachment) or a bare variable reference.
  func attachment(_ v: PlistValue?) -> String {
    guard let v else { return "" }
    return value(v) ?? ""
  }

  /// The attachment's value; nil when the variable or output was never set.
  func value(_ v: PlistValue) -> String? {
    let att = v["Value"] ?? v
    switch att["Type"]?.stringValue {
    case "ActionOutput": return outputs[att["OutputUUID"]?.stringValue ?? ""]
    case "Variable": return vars[att["VariableName"]?.stringValue ?? ""]
    default: return nil
    }
  }

  func resolve(_ att: PlistValue) -> String {
    switch att["Type"]?.stringValue {
    case "ActionOutput": return outputs[att["OutputUUID"]?.stringValue ?? ""] ?? ""
    case "Variable": return vars[att["VariableName"]?.stringValue ?? ""] ?? ""
    default: return ""
    }
  }

  /// A WFDictionaryFieldValue as text values.
  func fields(_ v: PlistValue?) -> [String: String] {
    var out: [String: String] = [:]
    for item in v?["Value"]?["WFDictionaryFieldValueItems"]?.arrayValue ?? [] {
      // Item type 0 is text: the only kind the builder emits, sent as a JSON string.
      precondition(item["WFItemType"] == .integer(0), "dictionary item of another type")
      out[text(item["WFKey"])] = text(item["WFValue"])
    }
    return out
  }
}
