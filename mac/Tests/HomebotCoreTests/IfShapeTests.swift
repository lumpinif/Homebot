// The loop Shortcuts' If actions against an If saved by the Shortcuts app itself (macOS 26, the
// same format as iOS 26). Fixtures/apple-if-macos26.plist is that action, taken from a file the
// app exported after "Get: Text" was chosen on the variable in the editor. Without that Text
// coercion the app offers only "has any value" for a Dictionary Value variable, drops the "is not"
// value and stops the Shortcut with "Please choose a value for each parameter in this action."
import Foundation
import HomebotTestSupport
import Testing

@testable import HomebotCore

@Suite("If actions match the Shortcuts app's own")
struct IfShapeTests {
  /// Dictionary keys sorted, as the app writes them, so key order does not matter.
  static func sorted(_ v: PlistValue) -> PlistValue {
    switch v {
    case .dict(let items): return .dict(items.sorted { $0.0 < $1.0 }.map { ($0.0, sorted($0.1)) })
    case .array(let a): return .array(a.map(sorted))
    default: return v
    }
  }

  static func apple() throws -> PlistValue {
    let url = try #require(Bundle.module.url(forResource: "apple-if-macos26.plist", withExtension: nil, subdirectory: "Fixtures"))
    return try ShortcutRunner.load(url)
  }

  /// Every opening If (mode 0) of a workflow.
  static func ifs(_ w: PlistValue) throws -> [PlistValue] {
    try #require(w["WFWorkflowActions"]?.arrayValue).filter {
      $0["WFWorkflowActionIdentifier"]?.stringValue == "is.workflow.actions.conditional" && $0["WFWorkflowActionParameters"]?["WFControlFlowMode"] == .integer(0)
    }.compactMap { $0["WFWorkflowActionParameters"] }
  }

  static let loops: [(String, PlistValue)] = {
    let b = ShortcutBuilder()
    return [
      ("conversation", try! b.conversationShortcut(baseUrl: "http://mac.local:8787", botKey: "b", token: "T", prompt: "?", speakLang: "zh-CN")),
      ("entry", try! b.entryShortcut(baseUrl: "http://mac.local:8787", token: "T", speakLang: "zh-CN")),
      ("lab", try! b.labShortcut(baseUrl: "http://mac.local:8787", token: "T", speakLang: "zh-CN")),
    ]
  }()

  @Test("the end check is the app's If byte for byte, apart from its UUIDs", arguments: ["conversation", "entry", "lab"])
  func endCheck(name: String) throws {
    let w = try #require(Self.loops.first { $0.0 == name }?.1)
    let apple = try #require(try Self.apple()["WFWorkflowActionParameters"])
    let mine = try Self.ifs(w).filter { $0["WFCondition"] == .integer(5) }
    #expect(mine.count == 2, "after step 0 and inside the loop")
    let drop: Set<String> = ["UUID", "GroupingIdentifier"]
    func strip(_ v: PlistValue) -> PlistValue {
      guard case .dict(let items) = v else { return v }
      return Self.sorted(.dict(items.filter { !drop.contains($0.0) }))
    }
    for p in mine { #expect(strip(p) == strip(apple)) }
  }

  @Test("every If reads its variable as Text and has a value to compare", arguments: ["conversation", "entry", "lab"])
  func everyIf(name: String) throws {
    let w = try #require(Self.loops.first { $0.0 == name }?.1)
    let appleInput = try #require(try Self.apple()["WFWorkflowActionParameters"]?["WFInput"]?["Variable"]?["Value"]?["Aggrandizements"])
    let all = try Self.ifs(w)
    #expect(all.count == 3, "start check, V1/V2 choice, end check")
    for p in all {
      #expect([.integer(4), .integer(5)].contains(p["WFCondition"]))
      #expect(p["WFConditionalActionString"]?.stringValue?.isEmpty == false)
      #expect(Self.sorted(try #require(p["WFInput"]?["Variable"]?["Value"]?["Aggrandizements"])) == appleInput)
    }
  }
}
