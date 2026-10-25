// Homebot's mark and the Grok Bot icon. The mark is a roofline over two eyes (the geometry of
// web/src/app/brand.tsx) on a rounded square: Glow's colourful light (the website logo), black or
// white. LiveMark (LiveMark.swift) moves its eyes.
import AppKit
import SwiftUI

/// One frame of the website logo's light (site `.hb-logo`), in the master SVG's tile units
/// (viewBox 0 0 120 120). A new frame from S17 (.agent-logs/s17-glow-icon) is a new value here.
struct GlowFrame {
  struct Field { var center: CGPoint; var color: UInt32; var opacity: Double; var radius: CGFloat = 81 }
  /// Scaled by `scale` and moved by `offset` about the patch centre (36.6, 36.6).
  struct Patch { var color: UInt32; var scale: CGFloat; var offset: CGPoint }

  var base: UInt32
  /// The turn of the square the fields and patches sit in (SVG matrix a b c d, about the centre).
  var flow: CGAffineTransform
  /// The static icon pulls the square in about the centre before turning it.
  var flowScale: CGFloat = 1
  var fields: [Field]
  var patches: [Patch]
  var patchOpacity: Double = 0.92
  var patchRadius: CGFloat = 57.6
  /// Top-down darkening: colour and opacity at the top, faded out by `shadeEnd` of the height.
  var shade: UInt32, shadeOpacity: Double, shadeEnd: Double
  /// Dark corners, over the breath: a radial from the centre to the corners, clear until `vignetteStart`.
  var vignette: UInt32? = nil, vignetteOpacity: Double = 0, vignetteStart: Double = 0.5
  /// Warm light from the bottom edge: an ellipse of `breathSize` centred `breathDrop` below it.
  var breath: UInt32, breathOpacity: Double, breathLayer: Double, breathScale: CGFloat
  var breathSize = CGSize(width: 84, height: 60), breathDrop: CGFloat = 12
  /// The glyph's drop shadow (SVG feDropShadow).
  var shadowBlur: CGFloat = 1.8, shadowDrop: CGFloat = 1.8, shadowOpacity: Double = 0.35

  /// t = 78 s (S17's master v4, Felix's pick): the first colourful logo with the square pulled
  /// in, near-black corners and edges from a four-corner vignette, a dark top so the roof reads,
  /// and a small warm ellipse low in the middle that stops short of the bottom corners.
  static let t78 = GlowFrame(
    base: 0x0d0b1a,
    flow: CGAffineTransform(a: -0.7071, b: -0.7071, c: 0.7071, d: -0.7071, tx: 0, ty: 0), flowScale: 0.88,
    fields: [],
    patches: [
      Patch(color: 0xff2bd6, scale: 1.0189, offset: CGPoint(x: -6.2013, y: 24.3647)),
      Patch(color: 0x2f5bff, scale: 0.9908, offset: CGPoint(x: 38.1074, y: 13.9809)),
      Patch(color: 0x22e6ff, scale: 1.0411, offset: CGPoint(x: 19.5306, y: 38.8557)),
      Patch(color: 0xff8a1f, scale: 0.9504, offset: CGPoint(x: 34.4681, y: 40.2167)),
      Patch(color: 0xff2555, scale: 1.0487, offset: CGPoint(x: 13.5171, y: 61.7061)),
    ],
    shade: 0x080614, shadeOpacity: 0.72, shadeEnd: 0.62,
    vignette: 0x080514, vignetteOpacity: 0.8, vignetteStart: 0.45,
    breath: 0xff9646, breathOpacity: 0.75, breathLayer: 0.45, breathScale: 0.911,
    breathSize: CGSize(width: 48, height: 40), breathDrop: 6)

  /// The frame Glow shows.
  static let current = t78
}

/// Glow's background: a GlowFrame drawn layer by layer as S17's master SVG does. Vector, so it is
/// sharp at any size.
struct GlowField: View {
  let size: CGFloat
  var frame = GlowFrame.current

  var body: some View {
    Canvas { ctx, _ in
      let f = frame
      ctx.scaleBy(x: size / 120, y: size / 120)
      let tile = CGRect(x: 0, y: 0, width: 120, height: 120)
      ctx.fill(Path(tile), with: .color(.hex(f.base)))

      var flow = ctx
      flow.translateBy(x: 60, y: 60)
      flow.scaleBy(x: f.flowScale, y: f.flowScale)
      flow.concatenate(f.flow)
      flow.translateBy(x: -60, y: -60)
      let square = Path(CGRect(x: -30, y: -30, width: 180, height: 180))
      for field in f.fields {
        let c = Color.hex(field.color)
        flow.fill(square, with: .radialGradient(Gradient(colors: [c.opacity(field.opacity), c.opacity(0)]), center: field.center, startRadius: 0, endRadius: field.radius))
      }
      for p in f.patches {
        var patch = flow
        patch.opacity = f.patchOpacity
        patch.translateBy(x: 36.6, y: 36.6)
        patch.concatenate(CGAffineTransform(a: p.scale, b: 0, c: 0, d: p.scale, tx: p.offset.x, ty: p.offset.y))
        patch.translateBy(x: -36.6, y: -36.6)
        let c = Color.hex(p.color)
        let g = Gradient(stops: [.init(color: c, location: 0), .init(color: c.opacity(0.6), location: 0.45), .init(color: c.opacity(0), location: 1)])
        let r = f.patchRadius
        patch.fill(Path(CGRect(x: 36.6 - r, y: 36.6 - r, width: 2 * r, height: 2 * r)), with: .radialGradient(g, center: CGPoint(x: 36.6, y: 36.6), startRadius: 0, endRadius: r))
      }

      let shade = Color.hex(f.shade)
      ctx.fill(Path(tile), with: .linearGradient(Gradient(stops: [.init(color: shade.opacity(f.shadeOpacity), location: 0), .init(color: shade.opacity(0), location: f.shadeEnd)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: 120)))

      var breath = ctx
      breath.clip(to: Path(tile))
      breath.opacity = f.breathLayer
      breath.translateBy(x: 60, y: 120)
      breath.scaleBy(x: f.breathScale, y: f.breathScale)
      breath.translateBy(x: 0, y: f.breathDrop)
      breath.scaleBy(x: f.breathSize.width, y: f.breathSize.height)
      let warm = Color.hex(f.breath)
      breath.fill(Path(CGRect(x: -3, y: -3, width: 6, height: 6)), with: .radialGradient(Gradient(colors: [warm.opacity(f.breathOpacity), warm.opacity(0)]), center: .zero, startRadius: 0, endRadius: 1))

      if let v = f.vignette {
        let dark = Color.hex(v)
        ctx.fill(Path(tile), with: .radialGradient(Gradient(stops: [.init(color: dark.opacity(0), location: f.vignetteStart), .init(color: dark.opacity(f.vignetteOpacity), location: 1)]),
                                                   center: CGPoint(x: 60, y: 60), startRadius: 0, endRadius: 60 * 2.squareRoot()))
      }
    }
    .frame(width: size, height: size)
  }
}

/// One frame of the mark. The SVG's viewBox is 5 5 54 54; `u` maps its units to points.
struct MarkDrawing: View, Animatable {
  let size: CGFloat
  var gaze: CGSize = .zero
  var blink: Double = 1
  /// The app icon variant: Glow draws the colourful light; Black and White are plain.
  var style: AppIcon = .glow

  /// The eyes animate (LiveMark): SwiftUI redraws the Canvas only while a change is in flight.
  nonisolated var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, Double> {
    get { AnimatablePair(AnimatablePair(gaze.width, gaze.height), blink) }
    set {
      gaze = CGSize(width: newValue.first.first, height: newValue.first.second)
      blink = newValue.second
    }
  }

  var body: some View {
    let u = size / 54
    let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
    ZStack {
      style.background
      if style == .glow { GlowField(size: size) }
      Canvas { ctx, _ in
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: (x - 5) * u, y: (y - 5) * u) }
        // Glow lifts the glyph off the light (the master's drop shadow, in 120-unit tile units).
        if style == .glow {
          let g = GlowFrame.current
          ctx.addFilter(.shadow(color: .black.opacity(g.shadowOpacity), radius: g.shadowBlur * size / 120, x: 0, y: g.shadowDrop * size / 120))
        }
        var roof = Path()
        roof.move(to: p(17, 31))
        roof.addLine(to: p(32, 19))
        roof.addLine(to: p(47, 31))
        ctx.stroke(roof, with: .color(style.foreground), style: StrokeStyle(lineWidth: 4.6 * u, lineCap: .round, lineJoin: .round))
        // Eyes: blink scales around y = 40, then the gaze moves both.
        for x in [23.3, 35.3] {
          let h = 11 * blink
          let y = 40 - (40 - 34.5) * blink
          let r = CGRect(x: (x - 5 + gaze.width) * u, y: (y - 5 + gaze.height) * u, width: 5.4 * u, height: h * u)
          ctx.fill(Path(roundedRect: r, cornerSize: CGSize(width: min(2.7 * u, r.height / 2), height: min(2.7 * u, r.height / 2))), with: .color(style.foreground))
        }
      }
      .frame(width: size, height: size)
    }
    .frame(width: size, height: size)
    .clipShape(shape)
    .overlay(shape.strokeBorder(style.rim, lineWidth: max(0.5, size / 64)))
  }
}

/// Siri's own SF Symbol (macOS 26 and later). Apple restricts it: unmodified, and only to refer
/// to Siri. Siri's orb and animation have no public API and are not imitated here.
public enum SiriSymbol {
  public static var available: Bool {
    if #available(macOS 26, *) { return true }
    return false
  }
}

/// Grok Bot's official app icon (the page's /grok-bot.png), shown the way the App Store and the
/// Home Screen show it. The file is App Store artwork: a full-bleed, opaque square that Apple
/// always presents inside its continuous-corner icon mask (22.37% of the side), so the square's
/// dark corners are not part of the visible icon. Nothing else changes: no tint, no border, no
/// motion (xAI's guidelines: logos "without any alteration").
public struct GrokBotAvatar: View {
  var size: CGFloat

  public init(size: CGFloat = 28) {
    self.size = size
  }

  static let image: NSImage? = Bundle.main.url(forResource: "grok-bot", withExtension: "png").flatMap(NSImage.init(contentsOf:))

  public var body: some View {
    Group {
      if let img = GrokBotAvatar.image {
        Image(nsImage: img).resizable().interpolation(.high)
      } else {
        Color.clear
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
    .accessibilityHidden(true)
  }
}
