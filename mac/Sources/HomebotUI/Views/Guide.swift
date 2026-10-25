// Visual guides (Help › Install or update, the iPhone step): a stage that plays drawn mini-scenes
// one step at a time, with a few words under each, step dots and arrows. Steps advance on their
// own with a soft slide and loop with a pause on the last one; a click on a dot or an arrow takes
// over for a while. Under Reduce Motion nothing moves by itself: each scene shows its end frame
// and the user steps through. The tour pauses while the pointer is over the stage and while the
// window is hidden, minimised or covered.
import SwiftUI

/// Which step of a tour shows, and when the next one is due. Pure: times are seconds on any clock
/// the caller passes in, so tests can drive it.
struct StepTour: Equatable {
  let count: Int
  private(set) var index = 0
  /// Steps advance by themselves (off under Reduce Motion).
  private(set) var auto: Bool
  /// How long each step shows.
  var dwell: Double = 4.2
  /// The extra hold on the last step before the tour starts over.
  var loopPause: Double = 2
  /// After the user picks a step, how long it stays before the tour goes on by itself.
  var manualHold: Double = 10
  /// When the next step is due; nil while stopped or paused.
  private(set) var due: Double?
  /// The time left on the current step while paused.
  private(set) var left: Double?

  init(count: Int, auto: Bool = true) {
    self.count = max(1, count)
    self.auto = auto
  }

  /// How long step `i` shows before the next.
  func hold(_ i: Int) -> Double { dwell + (i == count - 1 ? loopPause : 0) }

  var running: Bool { auto && count > 1 }
  var paused: Bool { left != nil }

  mutating func start(at now: Double) {
    left = nil
    due = running ? now + hold(index) : nil
  }

  /// Reduce Motion changed: start or stop advancing, on the same step.
  mutating func setAuto(_ on: Bool, at now: Double) {
    guard on != auto else { return }
    auto = on
    if on { start(at: now) } else { stop() }
  }

  mutating func stop() {
    due = nil
    left = nil
  }

  /// Moves on if the current step is due. The next deadline counts from this one, so a late wake
  /// doesn't stretch the loop, but never lies in the past.
  @discardableResult
  mutating func tick(at now: Double) -> Bool {
    guard let d = due, now >= d else { return false }
    index = (index + 1) % count
    let next = d + hold(index)
    due = next > now ? next : now + hold(index)
    return true
  }

  /// The user picked step `i` (wrapping): it holds for `manualHold`, also through a pause.
  mutating func go(to i: Int, at now: Double) {
    index = ((i % count) + count) % count
    guard running else { return }
    if paused { left = manualHold } else { due = now + manualHold }
  }

  mutating func next(at now: Double) { go(to: index + 1, at: now) }
  mutating func previous(at now: Double) { go(to: index - 1, at: now) }

  mutating func pause(at now: Double) {
    guard let d = due else { return }
    left = max(0, d - now)
    due = nil
  }

  mutating func resume(at now: Double) {
    guard let l = left else { return }
    due = now + l
    left = nil
  }
}

/// Drives a `StepTour` on a clock: sleeps until each deadline and advances. `generation` changes
/// whenever the user or a pause moves the deadline, so the view restarts the loop.
@MainActor @Observable
final class TourPlayer {
  var tour: StepTour
  /// Which way the last move went, for the slide direction.
  private(set) var forward = true
  private(set) var generation = 0
  @ObservationIgnored private var hovering = false
  @ObservationIgnored private var hidden = false
  @ObservationIgnored let now: () -> Double

  init(count: Int, auto: Bool, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
    tour = StepTour(count: count, auto: auto)
    self.now = now
    tour.start(at: now())
  }

  /// Sleeps to each deadline and advances (inside `animate`) until cancelled, the sleep throws or
  /// nothing is due.
  func run(sleep: (Double) async throws -> Void, animate: (() -> Void) -> Void = { $0() }) async {
    while let due = tour.due {
      do { try await sleep(max(0, due - now())) } catch { return }
      if Task.isCancelled { return }
      let t = now()
      if let d = tour.due, t >= d {
        forward = true
        animate { tour.tick(at: t) }
      }
    }
  }

  func go(to i: Int) {
    forward = i >= tour.index
    tour.go(to: i, at: now())
    generation += 1
  }

  func next() {
    forward = true
    tour.next(at: now())
    generation += 1
  }

  func previous() {
    forward = false
    tour.previous(at: now())
    generation += 1
  }

  /// Reduce Motion changed; a hover or hidden window still holds the step.
  func setAuto(_ on: Bool) {
    guard on != tour.auto else { return }
    tour.setAuto(on, at: now())
    syncPause()
    generation += 1
  }

  /// The pointer is over the stage: hold the step.
  func hover(_ on: Bool) {
    hovering = on
    syncPause()
  }

  /// The window is visible on screen.
  func visible(_ on: Bool) {
    hidden = !on
    syncPause()
  }

  private func syncPause() {
    let hold = hovering || hidden
    if hold, !tour.paused, tour.due != nil {
      tour.pause(at: now())
      generation += 1
    } else if !hold, tour.paused {
      tour.resume(at: now())
      generation += 1
    }
  }
}

/// A guide: the stage with the current step's scene, its caption, then arrows and step dots.
/// `scene(i, play)` draws step i; `play` is false under Reduce Motion (show the end frame).
struct GuidePlayer<Scene: View>: View {
  let captions: [String]
  var stageHeight: CGFloat = 250
  /// Accessibility names for the arrows and dots.
  let previous: String
  let next: String
  let stepLabel: (Int) -> String
  /// What stays still around the moving scenes (the iPhone's body); nil: none.
  var chrome: ((AnyView) -> AnyView)?
  @ViewBuilder let scene: (Int, Bool) -> Scene

  @Environment(\.accessibilityReduceMotion) private var reduce
  @State private var player: TourPlayer?

  var body: some View {
    let p = player
    let i = p?.tour.index ?? 0
    VStack(spacing: 12) {
      stage(i, p)
      HStack(spacing: 10) {
        arrow("chevron.left", previous) { p?.previous() }
        Text(captions.indices.contains(i) ? captions[i] : "")
          .font(.system(size: 15, weight: .semibold))
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .frame(maxWidth: .infinity)
          .frame(height: 40)
          .id(i)
          // The old words leave quickly, the new ones come in after: never two lines at once.
          .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.25).delay(0.12)), removal: .opacity.animation(.easeIn(duration: 0.1))))
          .accessibilityLabel("\(stepLabel(i)): \(captions.indices.contains(i) ? captions[i] : "")")
        arrow("chevron.right", next) { p?.next() }
      }
      .padding(.horizontal, Theme.inset)
      dots(i, p)
    }
    .onAppear { if player == nil { player = TourPlayer(count: captions.count, auto: !reduce) } }
    .onChange(of: reduce) { player?.setAuto(!reduce) }
    .task(id: p.map { "\(ObjectIdentifier($0).hashValue)-\($0.generation)" }) {
      guard let p else { return }
      await p.run(sleep: { try await Task.sleep(for: .seconds($0)) }) { change in
        withAnimation(Self.slide) { change() }
      }
    }
  }

  static var slide: Animation { .spring(response: 0.45, dampingFraction: 0.9) }

  func stage(_ i: Int, _ p: TourPlayer?) -> some View {
    let forward = p?.forward ?? true
    let move: AnyTransition = reduce ? .opacity : .asymmetric(
      insertion: .opacity.combined(with: .offset(x: forward ? 28 : -28)),
      removal: .opacity.combined(with: .offset(x: forward ? -28 : 28)))
    let moving = ZStack {
      // Keyed by Reduce Motion too, so a scene playing when it turns on restarts as its end frame.
      scene(i, !reduce)
        .id("\(i)-\(reduce)")
        .transition(move)
    }
    return Group {
      if let chrome { chrome(AnyView(moving)) } else { moving }
    }
    .frame(maxWidth: .infinity)
    .frame(height: stageHeight)
    .background(StageBackground())
    .clipShape(RoundedRectangle(cornerRadius: Theme.radius + 4, style: .continuous))
    .contentShape(Rectangle())
    .onHover { p?.hover($0) }
    .background(PointerProbe(onPointer: nil, onVisible: { p?.visible($0) }))
    .accessibilityHidden(true)
  }

  func arrow(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
    IconButton(symbol: symbol, help: label) {
      withAnimation(reduce ? .easeOut(duration: 0.2) : Self.slide) { action() }
    }
  }

  func dots(_ i: Int, _ p: TourPlayer?) -> some View {
    HStack(spacing: 2) {
      ForEach(captions.indices, id: \.self) { k in
        Button {
          withAnimation(reduce ? .easeOut(duration: 0.2) : Self.slide) { p?.go(to: k) }
        } label: {
          Circle()
            .fill(k == i ? Theme.primary : Color(nsColor: .tertiaryLabelColor))
            .frame(width: 7, height: 7)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(stepLabel(k))
        .accessibilityAddTraits(k == i ? .isSelected : [])
      }
    }
    .animation(.easeOut(duration: 0.2), value: i)
  }
}

/// The stage behind a scene: a quiet wash of the accent colour over the grouped fill.
struct StageBackground: View {
  var body: some View {
    ZStack {
      Theme.card
      LinearGradient(colors: [Theme.primary.opacity(0.10), Theme.primary.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
  }
}

/// A small (i) that opens the details behind a short line, so the page shows only the line.
struct InfoButton: View {
  let label: String
  let text: String
  /// An optional link under the text, for the details that don't belong in a popover.
  var link: (title: String, url: URL)? = nil
  @State private var open = false
  @State private var hover = false

  var body: some View {
    Button { open.toggle() } label: {
      Image(systemName: "info.circle")
        .font(.system(size: 13))
        .foregroundStyle(hover || open ? Theme.foreground : Theme.muted)
        .frame(width: Theme.infoButton, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .help(label)
    .accessibilityLabel(label)
    .popover(isPresented: $open, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 8) {
        Text(text)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        if let link {
          Link(destination: link.url) { Text(link.title).foregroundStyle(Theme.primary) }
            .pointerStyle(.link)
        }
      }
      .font(.system(size: 12))
      .frame(width: 280, alignment: .leading)
      .padding(14)
    }
  }
}

/// A label with its (i) or (?) right after it, on the text's baseline. The button's frame hugs its
/// 13 pt symbol (`Theme.infoButton`); with 2 pt spacing and the letters' own side bearing the
/// visible gap is about 5 pt (measured: 10 px at 2x).
struct InlineInfo<Label: View, Info: View>: View {
  @ViewBuilder var label: Label
  @ViewBuilder var info: Info

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 2) {
      label
      info
    }
  }
}

/// A tap on an iPhone screen, or a click: a ring that swells and fades, `count` times.
struct TapRipple: View {
  var color: Color = .white
  var size: CGFloat = 26
  /// When the first tap lands, in seconds after the scene appears.
  var delay: Double
  var count = 1
  var play = true
  @State private var phase = 0.0

  var body: some View {
    ZStack {
      Circle().fill(color.opacity(0.35 * (1 - phase)))
      Circle().strokeBorder(color.opacity(0.9 * (1 - phase)), lineWidth: 2)
    }
    .frame(width: size, height: size)
    .scaleEffect(0.5 + phase)
    .opacity(play ? 1 : 0)
    .allowsHitTesting(false)
    .task {
      guard play else { return }
      try? await Task.sleep(for: .seconds(delay))
      for _ in 0..<count {
        if Task.isCancelled { return }
        phase = 0
        withAnimation(.easeOut(duration: 0.5)) { phase = 1 }
        try? await Task.sleep(for: .seconds(0.55))
      }
    }
    .onAppear { if play { phase = 1 } }
  }
}
