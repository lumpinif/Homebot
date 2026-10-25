// The visual guides' step sequencing (Guide.swift): auto-advance with a pause on the last step,
// manual moves that hold, pause and resume, Reduce Motion, and the player on an injected clock.
import Testing
@testable import HomebotUI

private func tick(_ t: inout StepTour, _ now: Double) -> Bool { t.tick(at: now) }
private func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }

@Suite struct StepTourTests {
  @Test func advancesAndLoopsWithAPauseOnTheLastStep() {
    var t = StepTour(count: 3)
    t.start(at: 0)
    #expect(near(t.due, 4.2))
    #expect(!tick(&t, 4.1))
    #expect(tick(&t, 4.2))
    #expect(t.index == 1)
    #expect(tick(&t, 8.4))
    #expect(t.index == 2)
    // The last step holds dwell + loopPause.
    #expect(near(t.due, 8.4 + 4.2 + 2))
    #expect(tick(&t, 14.6 + 1e-9))
    #expect(t.index == 0)
  }

  @Test func aLateWakeNeitherStretchesTheLoopNorSchedulesThePast() {
    var t = StepTour(count: 4)
    t.start(at: 0)
    // Woken 0.5 s late: the next deadline counts from the missed one.
    #expect(tick(&t, 4.7))
    #expect(near(t.due, 8.4))
    // Woken far too late (the Mac slept): the next one is a full step from now.
    #expect(tick(&t, 100))
    #expect(near(t.due, 104.2))
  }

  @Test func manualMovesWrapAndHold() {
    var t = StepTour(count: 5)
    t.start(at: 0)
    t.previous(at: 1)
    #expect(t.index == 4)
    #expect(near(t.due, 11))
    t.next(at: 2)
    #expect(t.index == 0)
    t.go(to: 7, at: 3)
    #expect(t.index == 2)
    #expect(near(t.due, 13))
    #expect(!tick(&t, 12.9))
  }

  @Test func pauseKeepsTheTimeLeft() {
    var t = StepTour(count: 3)
    t.start(at: 0)
    t.pause(at: 3)
    #expect(t.paused && t.due == nil)
    #expect(!tick(&t, 50))
    t.resume(at: 50)
    #expect(near(t.due, 51.2))
    // A move while paused holds for manualHold once resumed.
    t.pause(at: 51)
    t.next(at: 51)
    t.resume(at: 60)
    #expect(near(t.due, 70))
  }

  @Test func reduceMotionNeverMovesByItself() {
    var t = StepTour(count: 5, auto: false)
    t.start(at: 0)
    #expect(t.due == nil)
    #expect(!tick(&t, 1000))
    t.next(at: 1)
    #expect(t.index == 1)
    #expect(t.due == nil)
    t.pause(at: 2)
    #expect(!t.paused)
  }

  @Test func oneStepDoesNotRun() {
    var t = StepTour(count: 1)
    t.start(at: 0)
    #expect(t.due == nil)
  }
}

@MainActor @Suite struct TourPlayerTests {
  struct Stop: Error {}

  /// Steps come at their deadlines on a fake clock, and the run ends when the clock stops.
  @Test func runsOnAnInjectedClock() async {
    var now = 0.0
    let p = TourPlayer(count: 3, auto: true, now: { now })
    var seen: [(Double, Int)] = []
    await p.run(sleep: { d in
      if seen.count == 6 { throw Stop() }
      #expect(d >= 0)
      now += d
    }) { change in
      change()
      seen.append((now, p.tour.index))
    }
    #expect(seen.map(\.1) == [1, 2, 0, 1, 2, 0])
    #expect(zip(seen.map(\.0), [4.2, 8.4, 14.6, 18.8, 23.0, 29.2]).allSatisfy { near($0, $1) })
  }

  @Test func hoverAndHiddenWindowPauseAndResume() {
    var now = 0.0
    let p = TourPlayer(count: 3, auto: true, now: { now })
    let g = p.generation
    now = 1
    p.hover(true)
    #expect(p.tour.paused)
    #expect(p.generation == g + 1)
    now = 30
    p.visible(false)
    p.hover(false)
    // Still hidden: stays paused.
    #expect(p.tour.paused)
    now = 40
    p.visible(true)
    #expect(near(p.tour.due, 43.2))
  }

  @Test func manualMovesSetTheSlideDirection() {
    let p = TourPlayer(count: 4, auto: true, now: { 0 })
    p.go(to: 2)
    #expect(p.forward)
    p.previous()
    #expect(!p.forward)
    #expect(p.tour.index == 1)
    p.next()
    #expect(p.forward)
  }

  /// Under Reduce Motion the run returns at once: nothing is ever due.
  @Test func reduceMotionRunReturns() async {
    let p = TourPlayer(count: 5, auto: false, now: { 0 })
    var slept = false
    await p.run(sleep: { _ in slept = true })
    #expect(!slept)
  }
}

@MainActor @Suite struct TourPlayerMotionTests {
  /// Turning Reduce Motion off while the window is covered keeps the guide paused.
  @Test func reduceMotionChangeKeepsTheHiddenPause() {
    var now = 0.0
    let p = TourPlayer(count: 3, auto: false, now: { now })
    p.visible(false)
    now = 5
    p.setAuto(true)
    #expect(p.tour.paused)
    #expect(p.tour.due == nil)
    now = 9
    p.visible(true)
    #expect(p.tour.due.map { abs($0 - 13.2) < 1e-9 } == true)
    // And on again → off: nothing is due.
    p.setAuto(false)
    #expect(p.tour.due == nil && !p.tour.paused)
  }
}
