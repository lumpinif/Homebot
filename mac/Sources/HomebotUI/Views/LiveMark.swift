// The live Homebot mark (sidebar and Home): the app icon's roof and eyes, drawn as vectors from
// MarkDrawing's geometry, with eyes that look toward the pointer when it comes near, and now and
// then blink or glance while idle. Under Reduce Motion, and while the window is hidden or covered,
// the mark stands still and nothing is scheduled. Between movements nothing redraws: each change
// is one SwiftUI animation of MarkDrawing's animatable gaze and blink.
import AppKit
import SwiftUI

/// Where the eyes look, in the mark's 54-unit grid (MarkDrawing's units).
enum EyeGaze {
  /// The pointer counts as near within this distance (points) of the mark's centre.
  static let reach: CGFloat = 220
  /// The farthest the eyes move: an ellipse, wider than tall, so they stay clear of the roof.
  static let maxX: CGFloat = 3.2
  static let maxY: CGFloat = 2.4

  /// The eye offset for a pointer at `vector` (points from the mark's centre, y down), or nil
  /// when the pointer is outside the window or farther than `reach`. The eyes turn fully once
  /// the pointer is past the mark's edge, and less while it is over the mark itself.
  static func offset(_ vector: CGSize?, markSize: CGFloat) -> CGSize? {
    guard let v = vector, v.width.isFinite, v.height.isFinite else { return nil }
    let d = (v.width * v.width + v.height * v.height).squareRoot()
    guard d <= reach else { return nil }
    guard d > 0.5 else { return .zero }
    let ramp = min(1, d / max(markSize, 1))
    // The unit direction scaled onto the ellipse's edge, then by the ramp.
    let ux = v.width / d, uy = v.height / d
    let k = 1 / ((ux * ux) / (maxX * maxX) + (uy * uy) / (maxY * maxY)).squareRoot()
    return CGSize(width: ux * k * ramp, height: uy * k * ramp)
  }

  /// Rounded to 0.1 unit (a fraction of a point at sidebar size), so small pointer moves don't
  /// start a new animation each.
  static func quantized(_ g: CGSize?) -> CGSize? {
    g.map { CGSize(width: ($0.width * 10).rounded() / 10, height: ($0.height * 10).rounded() / 10) }
  }
}

/// The idle life: a blink every 4–9 s at random; about one gap in three also has a short glance
/// left or right before its blink. Pure and seeded, so tests can step it.
struct MarkLife<R: RandomNumberGenerator> {
  enum Act: Equatable {
    case blink
    /// Look this far sideways (grid units, negative is left) and back.
    case glance(Double)
  }

  struct Step: Equatable {
    var delay: Double
    var act: Act
  }

  static var blinkGap: ClosedRange<Double> { 4...9 }
  static var glanceChance: Double { 0.35 }

  var rng: R
  private var pending: Step?

  init(rng: R) { self.rng = rng }

  /// The next act and the wait before it.
  mutating func next() -> Step {
    if let p = pending {
      pending = nil
      return p
    }
    let gap = Double.random(in: Self.blinkGap, using: &rng)
    guard Double.random(in: 0..<1, using: &rng) < Self.glanceChance else { return Step(delay: gap, act: .blink) }
    // The glance falls inside the gap, so blinks stay 4–9 s apart.
    let at = Double.random(in: 1.5...(min(3, gap - 1)), using: &rng)
    let side: Double = Bool.random(using: &rng) ? 1 : -1
    pending = Step(delay: gap - at, act: .blink)
    return Step(delay: at, act: .glance(side * Double.random(in: 1.8...2.8, using: &rng)))
  }

  /// Runs the life until the task is cancelled or `sleep` throws. Waits are measured from fixed
  /// deadlines on `now` (seconds), so the time an act takes doesn't stretch the gaps.
  @MainActor mutating func run(now: @MainActor () -> Double, sleep: @MainActor (Double) async throws -> Void, perform: @MainActor (Act) async -> Void) async {
    var due = now()
    while !Task.isCancelled {
      let s = next()
      due += s.delay
      do { try await sleep(max(0, due - now())) } catch { return }
      if Task.isCancelled { return }
      await perform(s.act)
    }
  }
}

struct LiveMark: View {
  let size: CGFloat
  var style: AppIcon = .glow
  @Environment(\.accessibilityReduceMotion) private var reduce
  @State private var follow: CGSize?
  @State private var glance: CGSize = .zero
  @State private var blink: Double = 1
  @State private var visible = true

  var body: some View {
    let live = !reduce && visible
    MarkDrawing(size: size, gaze: live ? (follow ?? glance) : .zero, blink: live ? blink : 1, style: style)
      .background(
        PointerProbe(
          onPointer: { v in
            guard live else { return }
            let g = EyeGaze.quantized(EyeGaze.offset(v, markSize: size))
            guard g != follow else { return }
            // Quick toward the pointer; slower and softer on the way back to centre.
            withAnimation(g == nil ? .spring(response: 0.7, dampingFraction: 0.85) : .spring(response: 0.35, dampingFraction: 0.78)) { follow = g }
          },
          onVisible: { visible = $0 }))
      .task(id: live) {
        guard live else {
          follow = nil
          glance = .zero
          blink = 1
          return
        }
        var life = MarkLife(rng: SystemRandomNumberGenerator())
        await life.run(now: { ProcessInfo.processInfo.systemUptime }, sleep: { try await Task.sleep(for: .seconds($0)) }) { act in await perform(act) }
      }
      .accessibilityHidden(true)
  }

  private func perform(_ act: MarkLife<SystemRandomNumberGenerator>.Act) async {
    switch act {
    case .blink:
      withAnimation(.easeIn(duration: 0.07)) { blink = 0.12 }
      try? await Task.sleep(for: .milliseconds(90))
      withAnimation(.easeOut(duration: 0.14)) { blink = 1 }
    case .glance(let x):
      // A glance only while the eyes aren't following the pointer.
      guard follow == nil else { return }
      withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { glance = CGSize(width: x, height: 0) }
      try? await Task.sleep(for: .milliseconds(Int.random(in: 700...1100)))
      withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { glance = .zero }
    }
  }
}

/// A view-sized, click-through NSView that reports the pointer anywhere in its window (as a vector
/// from its own centre, y down; nil when the pointer leaves the window) and whether the window is
/// visible on screen (not minimised, hidden or fully covered). The tracking area sits on the
/// window's content view and is active even while Homebot is in the background.
struct PointerProbe: NSViewRepresentable {
  var onPointer: ((CGSize?) -> Void)?
  var onVisible: (Bool) -> Void

  func makeNSView(context: Context) -> ProbeView { ProbeView() }

  func updateNSView(_ view: ProbeView, context: Context) {
    view.onPointer = onPointer
    view.onVisible = onVisible
  }

  static func dismantleNSView(_ view: ProbeView, coordinator: ()) { view.detach() }

  final class ProbeView: NSView {
    var onPointer: ((CGSize?) -> Void)?
    var onVisible: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    private weak var host: NSView?
    private var occlusion: NSObjectProtocol?
    private var scrolling: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      detach()
      guard let window else { return }
      occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.reportVisible() }
      }
      reportVisible()
      guard onPointer != nil, let content = window.contentView else { return }
      let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
      content.addTrackingArea(a)
      area = a
      host = content
      // Scrolling moves the mark under a still pointer: look again once the page has moved.
      scrolling = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
        if e.window === self?.window { DispatchQueue.main.async { self?.reportCurrent() } }
        return e
      }
      reportCurrent()
    }

    func detach() {
      if let a = area { host?.removeTrackingArea(a) }
      area = nil
      if let o = occlusion { NotificationCenter.default.removeObserver(o) }
      occlusion = nil
      if let m = scrolling { NSEvent.removeMonitor(m) }
      scrolling = nil
    }

    /// The pointer where it is now, or nil when it is outside the window's content.
    private func reportCurrent() {
      guard let window, let content = window.contentView else { return }
      let p = window.mouseLocationOutsideOfEventStream
      onPointer?(content.bounds.contains(content.convert(p, from: nil)) ? vector(p) : nil)
    }

    private func reportVisible() {
      guard let window else { return }
      let v = window.occlusionState.contains(.visible)
      DispatchQueue.main.async { [weak self] in
        self?.onVisible?(v)
        if v { self?.reportCurrent() }
      }
    }

    override func mouseMoved(with event: NSEvent) { report(event.locationInWindow) }
    override func mouseEntered(with event: NSEvent) { report(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { onPointer?(nil) }

    private func report(_ p: NSPoint) {
      guard window != nil else { return }
      onPointer?(vector(p))
    }

    /// From this view's centre to `p` (window coordinates), y down.
    private func vector(_ p: NSPoint) -> CGSize {
      let r = convert(bounds, to: nil)
      return CGSize(width: p.x - r.midX, height: r.midY - p.y)
    }
  }
}
