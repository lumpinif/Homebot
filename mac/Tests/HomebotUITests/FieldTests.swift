// Text fields show exactly what was typed: a typed space stays in the field (S12: the labelled
// fields were right-aligned, and AppKit doesn't draw a right-aligned field's trailing spaces), and
// trimming happens only where the value is checked or used.
import AppKit
import SwiftUI
import Testing

@testable import HomebotUI

@MainActor
@Suite(.serialized) struct FieldTests {
  final class Box { var text = "" }

  func textFields(_ v: NSView) -> [NSTextField] {
    (v as? NSTextField).map { [$0] } ?? [] + v.subviews.flatMap(textFields)
  }

  @Test func aTypedSpaceStaysInTheFieldAndIsTrimmedOnlyWhenChecked() async throws {
    let box = Box()
    let binding = Binding(get: { box.text }, set: { box.text = $0 })
    let host = NSHostingView(rootView: Field(label: "Phrase", text: binding).frame(width: 400))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    let field = try #require(textFields(host).first { $0.isEditable })
    #expect(field.alignment != .right, "a right-aligned field hides trailing spaces")

    #expect(window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? NSTextView)
    editor.insertText("a", replacementRange: editor.selectedRange())
    editor.insertText(" ", replacementRange: editor.selectedRange())
    for _ in 0..<3 {
      host.layoutSubtreeIfNeeded()
      try? await Task.sleep(nanoseconds: 30_000_000)
    }
    #expect(box.text == "a ")
    #expect(field.stringValue == "a ")
    #expect(ShortcutInput.phrase(box.text) == "a")
  }

  @Test func phraseNormalisation() {
    #expect(ShortcutInput.phrase("  Ask   Grok \t now ") == "Ask Grok now")
    #expect(ShortcutInput.phrase("   ") == nil)
    #expect(ShortcutInput.phrase("居家 助手") == "居家 助手")
  }

  @Test func lengthClampLeavesShortTextAlone() {
    #expect(Field.clamped("a ", 200) == nil)
    #expect(Field.clamped("abcdef", 3) == "abc")
  }
}
