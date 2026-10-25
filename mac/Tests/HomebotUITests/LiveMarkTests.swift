// The live mark (S11): where the eyes look for a pointer, the idle blinks and glances on a seeded
// generator and a fake clock, and Home's headline split into text, Grok Bot and Siri.
import CoreGraphics
import Testing

@testable import HomebotUI

/// A small seeded generator (SplitMix64), so a run is the same every time.
struct SeededRNG: RandomNumberGenerator {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

@Suite struct EyeGazeTests {
  /// Inside the ellipse (with rounding slack).
  func inside(_ g: CGSize) -> Bool {
    (g.width * g.width) / (EyeGaze.maxX * EyeGaze.maxX) + (g.height * g.height) / (EyeGaze.maxY * EyeGaze.maxY) <= 1.0001
  }

  @Test func outsideOrFarIsNil() {
    #expect(EyeGaze.offset(nil, markSize: 46) == nil)
    #expect(EyeGaze.offset(CGSize(width: EyeGaze.reach + 1, height: 0), markSize: 46) == nil)
    #expect(EyeGaze.offset(CGSize(width: 0, height: -400), markSize: 46) == nil)
    #expect(EyeGaze.offset(CGSize(width: CGFloat.infinity, height: 0), markSize: 46) == nil)
    #expect(EyeGaze.offset(CGSize(width: CGFloat.nan, height: 0), markSize: 46) == nil)
  }

  @Test func onTheCentreIsZero() {
    #expect(EyeGaze.offset(.zero, markSize: 46) == .zero)
  }

  @Test func looksTowardThePointer() throws {
    let right = try #require(EyeGaze.offset(CGSize(width: 150, height: 0), markSize: 46))
    #expect(abs(right.width - EyeGaze.maxX) < 0.001)
    #expect(abs(right.height) < 0.001)
    let up = try #require(EyeGaze.offset(CGSize(width: 0, height: -150), markSize: 46))
    #expect(abs(up.height + EyeGaze.maxY) < 0.001)
    let downLeft = try #require(EyeGaze.offset(CGSize(width: -100, height: 100), markSize: 46))
    #expect(downLeft.width < 0 && downLeft.height > 0)
  }

  @Test func clampedToTheEllipseEverywhere() throws {
    for dx in stride(from: -220.0, through: 220, by: 20) {
      for dy in stride(from: -220.0, through: 220, by: 20) {
        guard let g = EyeGaze.offset(CGSize(width: dx, height: dy), markSize: 28) else { continue }
        #expect(inside(g), "\(dx), \(dy) → \(g)")
      }
    }
  }

  @Test func turnsLessOverTheMarkItself() throws {
    let near = try #require(EyeGaze.offset(CGSize(width: 10, height: 0), markSize: 46))
    let past = try #require(EyeGaze.offset(CGSize(width: 60, height: 0), markSize: 46))
    #expect(near.width > 0 && near.width < past.width)
  }

  @Test func quantizedToATenthOfAUnit() {
    #expect(EyeGaze.quantized(CGSize(width: 1.234, height: -2.36)) == CGSize(width: 1.2, height: -2.4))
    #expect(EyeGaze.quantized(nil) == nil)
  }
}

@Suite struct MarkLifeTests {
  @Test func blinksStayFourToNineSecondsApart() {
    var life = MarkLife(rng: SeededRNG(state: 7))
    var sinceBlink = 0.0
    var blinks = 0, glances = 0
    for _ in 0..<2000 {
      let s = life.next()
      #expect(s.delay > 0)
      sinceBlink += s.delay
      switch s.act {
      case .blink:
        #expect(MarkLife<SeededRNG>.blinkGap.contains(sinceBlink), "gap \(sinceBlink)")
        sinceBlink = 0
        blinks += 1
      case .glance(let x):
        #expect((1.8...2.8).contains(abs(x)))
        // A glance comes 1.5–3 s after the blink before it.
        #expect((1.5...3).contains(sinceBlink))
        glances += 1
      }
    }
    // About one gap in three has a glance; both sides occur.
    #expect(glances > blinks / 5 && glances < blinks / 2)
  }

  @Test func glancesGoBothWays() {
    var life = MarkLife(rng: SeededRNG(state: 42))
    var sides = Set<Bool>()
    for _ in 0..<400 { if case .glance(let x) = life.next().act { sides.insert(x > 0) } }
    #expect(sides == [true, false])
  }

  @Test func sameSeedSameLife() {
    var a = MarkLife(rng: SeededRNG(state: 3)), b = MarkLife(rng: SeededRNG(state: 3))
    for _ in 0..<50 { #expect(a.next() == b.next()) }
  }

  /// The driver on a fake clock: each act comes at its deadline, even though acts take time
  /// (a glance holds about a second), and the run ends when the clock stops (the view's task is
  /// cancelled).
  @MainActor @Test func runsOnAnInjectedClock() async {
    struct Stop: Error {}
    var life = MarkLife(rng: SeededRNG(state: 11))
    var reference = MarkLife(rng: SeededRNG(state: 11))
    var now = 0.0
    var log: [(Double, MarkLife<SeededRNG>.Act)] = []
    await life.run(now: { now }, sleep: { d in
      if log.count == 20 { throw Stop() }
      #expect(d >= 0)
      now += d
    }) { act in
      log.append((now, act))
      now += act == .blink ? 0.09 : 1.1
    }
    #expect(log.count == 20)
    var t = 0.0
    for (at, act) in log {
      let s = reference.next()
      t += s.delay
      #expect(abs(at - t) < 1e-9)
      #expect(act == s.act)
    }
  }
}

@Suite struct HeroPartsTests {
  @Test func splitsAtTheMarks() {
    #expect(Hero.parts("Talk to your {bot} with {siri}.") == [.text("Talk to your "), .bot, .text(" with "), .siri, .text(".")])
    #expect(Hero.parts("{siri}로 {bot}에게 말합니다.") == [.siri, .text("로 "), .bot, .text("에게 말합니다.")])
    #expect(Hero.parts("plain") == [.text("plain")])
  }
}
