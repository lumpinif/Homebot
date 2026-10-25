// A colourful, slowly flowing orb next to the word "Siri" (Home's headline, the Shortcut step's
// conversation). Homebot's own drawing, in the hues of the mark's light; Apple has no public API
// for Siri's orb, and no code is copied from Apple or from recreations of it.
//  - Layers (OrbFrame): a dark glass sphere; four soft, saturated bands of light (magenta, blue,
//    cyan, orange) sweeping inside it, running white where they cross; a coloured rim and a
//    highlight; and a soft bloom around it that shows on light and dark windows. Every motion
//    repeats exactly once per `OrbFrame.period`.
//  - Playback: one loop is drawn once per size and screen scale (about 0.1 s), and Core Animation
//    plays it in the window server, cross-fading between frames. Redrawing the SwiftUI view every
//    frame cost about 25% of a core; this costs almost nothing in Homebot's process.
//  - It stands still under Reduce Motion (one frame) and pauses while the window is hidden or
//    covered.
//  - Edge: frames are drawn at twice the screen's backing scale and filtered down by Core
//    Animation (supersampling), and the sphere fades out over a feathered radial mask instead of
//    a hard circular clip, so the rim stays soft at 22 pt as well as large.
import AppKit
import QuartzCore
import SwiftUI

struct SiriOrb: View {
  let size: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduce

  var body: some View {
    OrbPlayer(size: size, still: reduce)
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

/// The drawn loops, by size and scale. Drawn on first use.
@MainActor
enum OrbFrames {
  /// Frames a second in the loop; Core Animation cross-fades between them.
  static let fps = 12.0
  /// Frames are drawn this many times finer than the screen and filtered down when shown: twice
  /// for the small inline sizes, where a pixel of rim shows; large orbs have room for their edge.
  static func oversample(_ size: CGFloat) -> CGFloat { size <= 32 ? 2 : 1 }
  private static var cache: [String: [CGImage]] = [:]

  static func loop(size: CGFloat, scale: CGFloat) -> [CGImage] {
    let key = "\(size)@\(scale)"
    if let c = cache[key] { return c }
    let n = Int(OrbFrame.period * fps)
    let frames = (0..<n).compactMap { i in image(size: size, scale: scale, t: Double(i) / fps) }
    cache[key] = frames
    return frames
  }

  static func image(size: CGFloat, scale: CGFloat, t: Double) -> CGImage? {
    let r = ImageRenderer(content: OrbFrame(size: size, t: t))
    r.scale = scale * oversample(size)
    return r.cgImage
  }
}

/// A layer that plays the orb's loop, or shows its still frame.
struct OrbPlayer: NSViewRepresentable {
  let size: CGFloat
  let still: Bool

  func makeNSView(context: Context) -> PlayerView { PlayerView(size: size) }

  func updateNSView(_ view: PlayerView, context: Context) {
    view.still = still
  }

  static func dismantleNSView(_ view: PlayerView, coordinator: ()) { view.stopWatching() }

  final class PlayerView: NSView {
    let size: CGFloat
    var still = false {
      didSet { if still != oldValue { reload() } }
    }
    private var occlusion: NSObjectProtocol?
    private var scale: CGFloat = 0
    /// The orb's own layer: AppKit manages the view's layer, a sublayer is ours.
    private let orb = CALayer()

    init(size: CGFloat) {
      self.size = size
      super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
      wantsLayer = true
      clipsToBounds = false
      orb.contentsGravity = .resizeAspect
      // The oversampled frames are averaged down, not point-sampled.
      orb.minificationFilter = .trilinear
      orb.magnificationFilter = .linear
      orb.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
      layer?.addSublayer(orb)
    }

    override func layout() {
      super.layout()
      // The bloom spills past the view's bounds; it never changes the layout.
      orb.frame = bounds.insetBy(dx: -size * (OrbFrame.bloom - 1) / 2, dy: -size * (OrbFrame.bloom - 1) / 2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopWatching()
      guard let window else { return }
      occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.syncPlaying() }
      }
      reload()
    }

    override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      if window != nil, window?.backingScaleFactor != scale { reload() }
    }

    func stopWatching() {
      if let o = occlusion { NotificationCenter.default.removeObserver(o) }
      occlusion = nil
    }

    private func reload() {
      guard let window else { return }
      let layer = orb
      scale = window.backingScaleFactor
      layer.contentsScale = scale * OrbFrames.oversample(size)
      layer.removeAnimation(forKey: "loop")
      if still {
        layer.contents = OrbFrames.image(size: size, scale: scale, t: OrbFrame.still)
        return
      }
      let frames = OrbFrames.loop(size: size, scale: scale)
      layer.contents = frames.first
      let a = CAKeyframeAnimation(keyPath: "contents")
      a.values = frames + [frames.first as Any]
      a.calculationMode = .linear
      a.duration = OrbFrame.period
      a.repeatCount = .infinity
      a.isRemovedOnCompletion = false
      layer.add(a, forKey: "loop")
      syncPlaying()
    }

    /// Pauses the loop while the window isn't visible, and resumes it where it stopped.
    private func syncPlaying() {
      guard let window else { return }
      let layer = orb
      let visible = window.occlusionState.contains(.visible)
      if !visible, layer.speed != 0 {
        let paused = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = paused
      } else if visible, layer.speed == 0 {
        let paused = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
      }
    }
  }
}

/// One frame of the orb at time `t` (seconds), on a canvas `bloom` times the orb's size so the
/// glow around it has room. Every motion repeats exactly once per `period`.
struct OrbFrame: View {
  let size: CGFloat
  let t: Double
  /// The canvas around the orb, as a multiple of its size (room for the bloom).
  static let bloom: CGFloat = 1.5
  /// The time of the still frame: the bands spread, all four hues showing.
  static let still: Double = 5
  /// One loop, in seconds.
  static let period: Double = 24
  /// One turn per loop, in radians a second.
  static let w = 2 * Double.pi / period

  /// The bands' hues: magenta, blue, cyan, orange.
  static let bands: [Color] = [.hex(0xff2bd6), .hex(0x2f5bff), .hex(0x22e6ff), .hex(0xff8a1f)]

  var body: some View {
    ZStack {
      glow
      sphere
    }
    .frame(width: size * Self.bloom, height: size * Self.bloom)
  }

  /// The soft light around the orb, in the bands' colours. Normal blending, so it shows on a
  /// light window as well as a dark one.
  private var glow: some View {
    Circle()
      .fill(AngularGradient(colors: Self.bands + [Self.bands[0]], center: .center, angle: .degrees(t * 15)))
      .frame(width: size * 0.98, height: size * 0.98)
      .blur(radius: size * 0.13)
      .opacity(0.55)
  }

  private var sphere: some View {
    ZStack {
      // Dark glass, a little lighter at the bottom where light passes through.
      RadialGradient(colors: [.hex(0x2a1f6b), .hex(0x07051a)], center: UnitPoint(x: 0.5, y: 0.62), startRadius: 0, endRadius: size * 0.55)
      ForEach(0..<4, id: \.self) { i in band(i) }
      // Where the bands cross, the light runs white.
      RadialGradient(colors: [.white.opacity(0.4 + 0.1 * sin(t * Self.w * 3)), .white.opacity(0)], center: UnitPoint(x: 0.5 + 0.06 * sin(t * Self.w * 2), y: 0.52), startRadius: 0, endRadius: size * 0.16)
        .blendMode(.plusLighter)
      // The glass: a soft rim in the bands' colours, inside the feathered edge, and a highlight on top.
      Circle()
        .strokeBorder(AngularGradient(colors: Self.bands + [Self.bands[0]], center: .center, angle: .degrees(-t * 15 + 90)), lineWidth: max(1, size * 0.05))
        .padding(Self.feather(size) * 0.6)
        .opacity(0.5)
        .blur(radius: max(0.5, size * 0.025))
        .blendMode(.plusLighter)
      Ellipse()
        .fill(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
        .frame(width: size * 0.54, height: size * 0.26)
        .offset(y: -size * 0.3)
        .blur(radius: size * 0.03)
        .blendMode(.plusLighter)
    }
    .frame(width: size, height: size)
    // A feathered edge, not a hard clip: opaque to `feather` inside the rim, clear at the rim.
    .mask(
      Circle().fill(RadialGradient(stops: [
        .init(color: .white, location: 1 - Self.feather(size) / (size / 2)),
        .init(color: .white.opacity(0), location: 1),
      ], center: .center, startRadius: 0, endRadius: size / 2)))
    .drawingGroup()
  }

  /// The width of the sphere's soft edge in points: about 1.5 px at 22 pt on a 2x screen,
  /// growing with the orb.
  static func feather(_ size: CGFloat) -> CGFloat { max(0.6, size * 0.034) }

  /// One luminous band: a thick, soft arc of colour that sweeps around inside the sphere and
  /// rises and falls, each at its own whole-number pace.
  private func band(_ i: Int) -> some View {
    let k = Double(i)
    let turn = t * 15 * (i.isMultiple(of: 2) ? 1 : -1) * (1 + Double(i % 2)) + k * 90
    let lift = sin(t * Self.w * Double(1 + i % 2) + k * 1.7) * 0.12
    let squash = 0.42 + 0.12 * sin(t * Self.w * Double(2 + i % 2) + k)
    let reach = [0.92, 0.8, 0.86, 0.72][i]
    // An open arc, so the bands read as ribbons of light, not rings.
    let span = 0.42 + 0.08 * sin(t * Self.w * 2 + k * 2.3)
    return Ellipse()
      .trim(from: 0, to: span)
      .stroke(Self.bands[i], style: StrokeStyle(lineWidth: size * 0.13, lineCap: .round))
      .frame(width: size * reach, height: size * squash * reach)
      .rotationEffect(.degrees(turn))
      .offset(y: size * lift)
      .blur(radius: size * 0.05)
      .opacity(0.95)
      .blendMode(.plusLighter)
  }
}
