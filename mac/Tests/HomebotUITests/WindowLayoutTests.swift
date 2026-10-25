// The window's content keeps the window's size whatever the page shows: a toast, a QR code or a
// long page never makes the split view taller than the window (S8: a toast in the detail's ZStack
// laid the page out at its full content height and pushed the whole window content up).
import AppKit
import SwiftUI
import Testing

import HomebotCore
import HomebotTestSupport
@testable import HomebotUI

@MainActor
@Suite(.serialized) struct WindowLayoutTests {
  /// The tallest subview frame inside the hosted window content. A scroll view's document may be
  /// taller than the window (that is what scrolls), so a clip view counts at its own height.
  func tallest(_ v: NSView) -> CGFloat {
    if v is NSClipView { return v.frame.height }
    return v.subviews.reduce(v.frame.height) { max($0, tallest($1)) }
  }

  @Test func toastsNeverGrowTheWindowContent() async throws {
    let m = try await makeModel(FakeGrokBot())
    defer { Task { await m.shutdown() } }
    await m.launch()
    m.go(.help) // a page taller than the window
    let host = NSHostingView(rootView: RootView().environment(m))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 760), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    func settle() async {
      for _ in 0..<6 {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 50_000_000)
      }
    }
    await settle()
    let before = tallest(host)
    #expect(before <= 760.5, "the content fits the window before any toast (\(before))")
    for i in 0..<3 { m.toast("A message long enough to wrap onto a second line in the toast, number \(i).", .error) }
    await settle()
    let after = tallest(host)
    #expect(after <= 760.5, "a toast never makes the content taller than the window (\(after))")
    window.close()
  }

  /// A toast is as wide as its icon and text; a long one stops at the width cap and wraps.
  @Test func toastsHugTheirContent() {
    func width(_ text: String, in w: CGFloat) -> CGFloat {
      NSHostingController(rootView: ToastView(toast: Toast(text: text, kind: .success)))
        .sizeThatFits(in: CGSize(width: w, height: 400)).width
    }
    let short = width("Copied.", in: 1000)
    #expect(short < 160, "a short toast hugs its text (\(short))")
    let long = width(String(repeating: "A long message that has to wrap. ", count: 6), in: ToastView.maxWidth)
    #expect(long <= ToastView.maxWidth + 0.5, "a long toast wraps inside the stack's cap (\(long))")
    #expect(long > short)
  }

  @Test func iPhoneStepOffersOnlyWhatIsThere() {
    let b = ShortcutBuild(tokenId: "t1", name: "居家助手", signed: true, steps: [])
    func file(_ t: TokenView, _ has: Bool) -> TokenView { var t = t; t.hasFile = has; return t }
    #expect(PhoneDelivery.of(b, [file(token("t1", state: .pending), true)]) == .send)
    // In use: the file was cleaned up on purpose, so the step says it is on the iPhone.
    #expect(PhoneDelivery.of(b, [token("t1", state: .active)]) == .installed)
    // Never used, file expired or cleaned up: no AirDrop or QR code for a missing file.
    #expect(PhoneDelivery.of(b, [file(token("t1", state: .pending), false)]) == .gone)
    #expect(PhoneDelivery.of(b, []) == .gone)
    // A new copy: one in use (on a device) is never replaced, a lost one is.
    #expect(!PhoneDelivery.installed.copyReplaces && PhoneDelivery.gone.copyReplaces)
    // On the phone but not answered yet (DECISIONS 27): no file to send, not "installed", and a
    // copy for another iPhone still replaces nothing.
    var trying = token("t1", bot: "kitchen", state: .pending)
    trying.usedAt = 5
    trying.replaces = "t0"
    #expect(PhoneDelivery.of(b, [trying]) == .trying)
    #expect(PhoneDelivery.trying.onDevice && !PhoneDelivery.trying.copyReplaces)
  }

  @Test func aReplacementWaitingForItsFirstAnswerIsOnItsWay() {
    var s = Snapshot(bots: [BotView(key: "a", name: "A", sessionId: "1", strictEcho: true, synced: true)], siriLangBefore: "zh-CN")
    var old = token("old", bot: "a", state: .active, siriLang: "zh-CN")
    var next = token("next", bot: "a", state: .pending)
    next.replaces = "old"
    s.tokens = [old, next]
    #expect(Flow.languageSuggestion(s).map(\.id) == ["old"], "unused and its file gone: it can be made again")
    s.tokens[1].usedAt = 5
    #expect(Flow.languageSuggestion(s).isEmpty, "used, waiting for its first answer: not offered twice")
    #expect(s.tokens[1].waitingForAnswer && !s.tokens[0].waitingForAnswer)
  }
}
