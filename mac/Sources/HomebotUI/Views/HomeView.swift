// Home (DESIGN §20.6): an at-a-glance status view. The headline (the sidebar carries the mark) and whether
// Siri can reach this Mac (a breathing dot and one word; the address is in Settings › About); the Grok Bot key, the working
// Shortcuts and the last request as three equal tiles that open their page (or perform the fix when something is wrong), then the activity list
// with full question and answer text, outcome and timings, and Clear, over one quiet privacy line. Make Shortcut is the
// toolbar's + button; Settings is in the sidebar and under Cmd-, (not repeated here). The Mac's
// own switches (open at login, keep awake) live in Settings; Home only links there until the user
// closes the hint.
import AppKit
import HomebotCore
import SwiftUI

struct HomeView: View {
  @Environment(AppModel.self) private var model
  let go: (Page) -> Void
  /// The page's scroll view (Detail's), for the last-request tile.
  let scroll: ScrollViewProxy
  @State private var confirmClear = false

  var body: some View {
    let T = model.tr
    VStack(alignment: .leading, spacing: Theme.gap) {
      VStack(alignment: .leading, spacing: Theme.rowGap) {
        hero
        tiles
        notices
      }
      activity.id(HomeView.activityID)
    }
    .alert(T.confirmClear, isPresented: $confirmClear) {
      Button(T.cancel, role: .cancel) {}
      Button(T.clear, role: .destructive) { Task { await model.clearActivity() } }
    } message: {
      Text(T.confirmClearBody)
    }
  }

  var running: Bool { model.status?.running == true }

  /// The one thing that matters most: Siri can reach Homebot on this Mac, or why not.
  var hero: some View {
    let T = model.tr
    let failed = !running && model.startFailed
    // "Ready" only when Siri can get an answer: the gateway runs, the key is usable and a
    // Shortcut has answered (`Flow.isSetUp`). Running with setup unfinished is orange and opens
    // the first step not done.
    let ready = running && model.setUp
    let unfinished = running && !ready
    let state = ready ? T.gatewayRunning : unfinished ? T.gatewayUnfinished : failed ? T.gatewayFailedShort : T.gatewayStopped
    return HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        Hero(template: T.heroTitle, size: 22)
          .id(T.lang)
          .transition(.opacity)
        // One plain word: green and breathing when ready, orange when stopped, red when it
        // couldn't start (the reason is in the tooltip). No address here (Settings › About).
        Button { if unfinished { go(Flow.startPage(model.snapshot)) } } label: {
          HStack(spacing: 6) {
            LiveDot(live: ready, failed: failed)
            Text(state)
              .font(.system(size: 13))
              .foregroundStyle(Theme.muted)
          }
        }
        .buttonStyle(.plain)
        .pointerStyle(unfinished ? .link : nil)
        .help(failed ? T.gatewayFailed : "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(T.statusGateway): \(state)")
      }
      Spacer(minLength: 12)
      if !running {
        Button(T.startAgain) { Task { await model.startGateway(); await model.refresh() } }.primaryAction()
      }
    }
    .padding(.vertical, 4)
  }

  static let activityID = "activity"

  /// Grok Bot, Shortcuts and the last request: three tiles of one size. Each is one button: it
  /// opens its page, or performs the fix it shows; the last request scrolls to Activity.
  var tiles: some View {
    let T = model.tr
    let s = model.snapshot
    let key = HomeStatus.key(s, T)
    let shortcuts = HomeStatus.shortcuts(s, T)
    let last = HomeStatus.last(model.status, T)
    return HStack(spacing: Theme.rowGap) {
      StatusTile(symbol: "key.fill", tint: Theme.primary, title: T.statusKey, state: key, destination: T.stepAccount) { go(.account) }
      StatusTile(symbol: "waveform", tint: Color(nsColor: .systemPink), title: T.statusShortcut, state: shortcuts, destination: T.shortcutsTitle) {
        go(shortcuts.page ?? (shortcuts.fix == nil ? .shortcuts : model.makeShortcutPage))
      }
      StatusTile(symbol: "clock.fill", tint: Color(nsColor: .systemIndigo), title: T.statusLast, state: last, destination: T.activityTitle,
                 action: model.activity.isEmpty ? nil : {
                   withAnimation(Motion.reduced ? nil : Motion.snappy) { scroll.scrollTo(HomeView.activityID, anchor: .top) }
                 })
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  /// Problems that need the user, each with its fix: keep-awake off, text history off, and the
  /// first-run hint that Settings has the Mac's own switches.
  @ViewBuilder
  var notices: some View {
    let T = model.tr
    // Asked once, after setup (DECISIONS item 38): nothing is sent unless the user says Share;
    // either answer is final here, and Settings › This Mac can change it.
    if model.asksUsage {
      Callout(text: T.usageAsk, style: .info) {
        HStack(spacing: 8) {
          Link(destination: privacyURL) { Image(systemName: "info.circle") }
            .buttonStyle(.borderless).foregroundStyle(Theme.muted).help(T.usageWhatsSent).accessibilityLabel(T.usageWhatsSent)
          Button(T.notNow) { Task { await model.setUsageCounts(false) } }.buttonStyle(.borderless).controlSize(.regular)
          Button(T.usageAskShare) { Task { await model.setUsageCounts(true) } }.secondaryAction().controlSize(.regular)
        }
      }
    }
    // The real state, not the switch: a sleep assertion that failed shows here too.
    if running && model.status?.awake != true {
      Callout(text: T.awakeOff, title: T.statusAwake) {
        if model.prefs.keepAwake == false {
          Button(T.turnOn) { Task { await model.setKeepAwake(true) } }.secondaryAction().controlSize(.regular)
        }
      }
    }
    if model.status?.textHistory == false && running { Callout(text: T.textHistoryOff) }
    if !model.prefs.macHintsDone {
      Callout(text: T.macTitle, style: .info) {
        HStack(spacing: 8) {
          Button(T.done) { model.finishMacHints() }.buttonStyle(.borderless).controlSize(.regular)
          Button(T.navSettings) { go(.settings) }.secondaryAction().controlSize(.regular)
        }
      }
    }
  }

  var activity: some View {
    let T = model.tr
    return VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        SectionTitle(text: T.activityTitle) {
          // Answers came back as text only: how to make the iPhone speak.
          if !model.activity.isEmpty { SpeakHelp() }
        }
        // Where the questions are kept, next to Clear; when the row is tight, the lock alone
        // (its words in the tooltip).
        ViewThatFits(in: .horizontal) {
          privacy(full: true)
          privacy(full: false)
        }
        .layoutPriority(1)
        .padding(.trailing, model.activity.isEmpty ? Theme.inset : 0)
        if !model.activity.isEmpty {
          Button(T.clear) { confirmClear = true }.buttonStyle(.borderless).padding(.trailing, Theme.inset)
        }
      }
      if model.activity.isEmpty {
        // A section of Home, not a page: the same empty state, in the section's card.
        EmptyState(title: T.emptyActivity, symbol: "waveform", note: T.emptyActivityNote)
          .padding(.vertical, 4)
          .frame(maxWidth: .infinity)
          .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
      } else {
        GroupBox {
          ForEach(model.activity, id: \.id) { r in ActivityRow(record: r) }
        }
      }
    }
  }

  /// "Stored only on this Mac" with its (i); the details are behind (i). Network and sleep notes
  /// live in Help.
  func privacy(full: Bool) -> some View {
    let T = model.tr
    return HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: "lock.fill").font(.system(size: 10))
      if full { Text(T.privacyShort).font(.system(size: 12)).lineLimit(1) }
      InfoButton(label: T.privacyMore, text: T.activityNote)
    }
    .foregroundStyle(Theme.muted)
    .fixedSize()
    .help(full ? "" : T.privacyShort)
  }
}

/// One state at a glance, as one button: a tinted symbol, its mark (green only when checked and
/// fine, orange when it needs the user, grey when there is nothing to judge yet) and a chevron,
/// what it is, its state, and the fix it performs when there is a problem. Hover and press change
/// the fill only. Tiles in a row share one height.
struct StatusTile: View {
  let symbol: String
  let tint: Color
  let title: String
  let state: TileState
  /// The page the tile opens, for VoiceOver when it shows no fix.
  let destination: String
  /// nil: the tile is not a button (nothing to open).
  let action: (() -> Void)?

  init(symbol: String, tint: Color, title: String, state: TileState, destination: String, action: (() -> Void)?) {
    self.symbol = symbol
    self.tint = tint
    self.title = title
    self.state = state
    self.destination = destination
    self.action = action
  }

  var body: some View {
    if let action {
      Button(action: action) { content(chevron: true) }
        .buttonStyle(TileButtonStyle())
        .accessibilityLabel("\(title): \(state.value)")
        .accessibilityHint(state.fix ?? destination)
    } else {
      content(chevron: false)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(state.value)")
    }
  }

  func content(chevron: Bool) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 6) {
        Image(systemName: symbol)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 26, height: 26)
          .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        Spacer(minLength: 4)
        mark
        if chevron {
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
        }
      }
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
        Text(state.value)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Theme.foreground)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
        if let fix = state.fix {
          Text(fix).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.primary).lineLimit(1)
            .padding(.top, 2)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(Theme.inset)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
  }

  var mark: some View {
    let (name, color): (String, Color) = switch state.mark {
    case .ok: ("checkmark.circle.fill", Theme.success)
    case .problem: ("exclamationmark.circle.fill", Theme.warning)
    case .neutral: ("minus.circle.fill", Color(nsColor: .tertiaryLabelColor))
    }
    return Image(systemName: name).font(.system(size: 14)).foregroundStyle(color)
  }
}

/// A status tile's button: the grouped fill, a step stronger under the pointer and again while
/// pressed (colour only: no scale, no weight change).
struct TileButtonStyle: ButtonStyle {
  @State private var hover = false

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
    configuration.label
      .background(Theme.card, in: shape)
      .overlay {
        shape.fill(configuration.isPressed ? Theme.active : hover ? Theme.hover : .clear)
          .allowsHitTesting(false)
      }
      .onHover { hover = $0 }
      .animation(.snappy(duration: 0.16), value: hover)
  }
}

/// One request in the activity list: what was asked, what Siri said, then when, which bot, the
/// outcome, then the timings, in quiet lines that wrap rather than cut.
struct ActivityRow: View {
  @Environment(AppModel.self) private var model
  let record: ActivityRecord
  @State private var expanded = false
  @State private var fullHeight: CGFloat = 0
  @State private var shownHeight: CGFloat = 0

  var body: some View {
    let T = model.tr
    let r = record
    let line = ActivityLine(r, T: T, manyBots: model.snapshot.bots.count > 1)
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        if let q = r.question {
          (Text(q) + (r.tooLong ? Text(" … (\(T.tooLongMark))").foregroundColor(Theme.muted) : Text("")))
            .font(.system(size: 13, weight: .medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } else {
          Text(r.label).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
        }
        Spacer(minLength: 8)
        // Answered is the normal case: only other outcomes are marked.
        if line.showsOutcome {
          Badge(text: T.outcomeLabel(r.outcome), style: HomeStatus.outcomeStyle(r.outcome), dot: true)
        }
      }
      if let n = line.note {
        Text(n).font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
      } else if let a = line.spoken {
        answer(a, T)
      }
      Text(line.meta)
        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
        .lineLimit(1).truncationMode(.middle)
    }
    .padding(.horizontal, Theme.inset)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .help(line.details)
  }

  /// At most three lines, with Show more when the answer is longer. The full text is laid out
  /// hidden behind it to know whether it was cut.
  @ViewBuilder func answer(_ a: String, _ T: Tr) -> some View {
    let cut = fullHeight > shownHeight + 1
    Text(a).font(.system(size: 13)).foregroundStyle(Theme.muted).textSelection(.enabled)
      .lineLimit(expanded ? nil : 3)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
      .background(alignment: .topLeading) {
        Text(a).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
          .hidden()
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
      }
    if cut || expanded {
      Button(expanded ? T.showLess : T.showMore) {
        withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
      }
      .buttonStyle(.link)
      .font(.system(size: 12))
    }
  }
}

/// The running state's dot: green and softly pulsing while Siri can reach Homebot, orange and
/// still otherwise (and still under Reduce Motion). The pulse is a Core Animation opacity loop
/// that runs in the window server; SwiftUI's repeating symbol effect redrew the page every frame
/// (about 9% of a core).
struct LiveDot: View {
  let live: Bool
  var failed = false
  @Environment(\.accessibilityReduceMotion) private var reduce

  var body: some View {
    DotLayer(live: live, failed: failed, pulse: live && !reduce)
      .frame(width: 7, height: 7)
      .accessibilityHidden(true)
  }
}

private struct DotLayer: NSViewRepresentable {
  let live: Bool
  let failed: Bool
  let pulse: Bool

  func makeNSView(context: Context) -> DotView { DotView() }

  func updateNSView(_ view: DotView, context: Context) {
    view.live = live
    view.failed = failed
    view.pulse = pulse
    view.needsDisplay = true
    view.syncPulse()
  }

  final class DotView: NSView {
    var live = true
    var failed = false
    var pulse = false
    private let dot = CALayer()

    override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
      layer?.addSublayer(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
      super.layout()
      dot.frame = bounds
      dot.cornerRadius = bounds.width / 2
    }

    /// The colour follows the appearance (system green and orange differ in dark mode).
    override func updateLayer() {
      effectiveAppearance.performAsCurrentDrawingAppearance {
        dot.backgroundColor = (live ? NSColor.systemGreen : failed ? NSColor.systemRed : NSColor.systemOrange).cgColor
      }
    }

    func syncPulse() {
      let running = dot.animation(forKey: "pulse") != nil
      if pulse, !running {
        // A slow breath: fades and shrinks a little, then back (on the layer, so no layout moves).
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0.45
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = 0.8
        let a = CAAnimationGroup()
        a.animations = [fade, shrink]
        a.duration = 1.6
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(a, forKey: "pulse")
      } else if !pulse, running {
        dot.removeAnimation(forKey: "pulse")
      }
    }
  }
}
