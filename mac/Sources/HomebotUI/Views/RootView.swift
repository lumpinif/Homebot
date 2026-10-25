// The window: a sidebar (the page's hero title and step rail, plus Home, Shortcuts and Settings)
// and the chosen page, on the window's own background with the page name in the unified toolbar,
// as Notes and System Settings do. Setup steps sit directly on that canvas and slide between each
// other. On macOS 26 the sidebar and toolbar are Liquid Glass.
import SwiftUI
import HomebotCore

public struct RootView: View {
  @Environment(AppModel.self) private var model
  @State private var dir: CGFloat = 1

  public init() {}

  public var body: some View {
    NavigationSplitView {
      Sidebar(go: go)
        .navigationSplitViewColumnWidth(min: 248, ideal: 264, max: 300)
    } detail: {
      Group {
        if model.loaded {
          Detail(dir: dir, go: go)
        } else {
          ProgressView().controlSize(.large)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      // Toasts float over the page and never take part in its size. As a sibling in a ZStack,
      // a toast appearing made the split view lay the page out at its full content height,
      // which pushed the whole window content up and the toast below the window (S8).
      .overlay(alignment: .bottom) { ToastStack() }
      .navigationTitle(pageTitle)
      .toolbar { Toolbar(go: go) }
    }
    .frame(minWidth: 860, minHeight: 620)
    .environment(\.locale, model.tr.locale)
    .alert(item: Binding(get: { model.renamedNotice }, set: { model.renamedNotice = $0 })) { n in
      Alert(
        title: Text(model.tr.fmt(model.tr.createdSameName, ["name": n.name])),
        message: Text(model.tr.errors("created-new") ?? ""),
        primaryButton: .destructive(Text(model.tr.removeFromHomebot)) { Task { await model.removeBot(n.key) } },
        secondaryButton: .cancel(Text(model.tr.cancel)))
    }
  }

  func go(_ page: Page) {
    let p = Flow.landing(page, model.snapshot)
    let order = Page.allCases
    dir = (order.firstIndex(of: p) ?? 0) >= (order.firstIndex(of: model.page) ?? 0) ? 1 : -1
    withAnimation(Motion.reduced ? .easeOut(duration: 0.15) : Motion.snappy) { model.go(p) }
  }

  /// The page's name in the toolbar (the window title).
  var pageTitle: String {
    let T = model.tr
    switch model.page {
    case .home: return T.navHome
    case .account: return T.stepAccount
    case .bot: return T.stepBot
    case .shortcut: return T.stepShortcut
    case .install: return T.install
    case .shortcuts: return T.shortcutsTitle
    case .settings: return T.settingsTitle
    case .help: return T.helpTitle
    }
  }
}

// MARK: sidebar

struct Sidebar: View {
  @Environment(AppModel.self) private var model
  let go: (Page) -> Void
  @Namespace private var rail

  var body: some View {
    let T = model.tr
    let p = model.progress
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        SidebarBrand()
        GlideHover(space: "rail", radius: 8, disabled: Set(Page.steps.filter { p[$0]?.open == false }.map(\.rawValue))) {
          VStack(alignment: .leading, spacing: 1) {
            RailItem(page: .home, title: T.navHome, symbol: "house", ns: rail, go: go)
            Text(T.navSetupGroup)
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(Theme.muted)
              .padding(.horizontal, 8)
              .padding(.top, 12)
              .padding(.bottom, 3)
            ForEach(Array(Page.steps.enumerated()), id: \.element) { i, step in
              RailItem(page: step, title: stepTitle(step), number: i + 1, state: p[step], ns: rail, go: go)
            }
            Divider().padding(.vertical, 8).padding(.horizontal, 8)
            RailItem(page: .shortcuts, title: T.tabShortcuts, symbol: "waveform", count: model.snapshot.liveTokens.count, ns: rail, go: go)
            RailItem(page: .settings, title: T.navSettings, symbol: "gearshape", ns: rail, go: go)
            RailItem(page: .help, title: T.navHelp, symbol: "questionmark.circle", ns: rail, go: go)
          }
        }
      }
      .padding(.horizontal, 10)
      .padding(.top, 6)
      .padding(.bottom, 20)
    }
    .scrollIndicators(.never)
  }

  func stepTitle(_ p: Page) -> String {
    let T = model.tr
    switch p {
    case .account: return T.stepAccount
    case .bot: return T.stepBot
    case .shortcut: return T.stepShortcut
    case .install: return T.install
    default: return ""
    }
  }
}

/// The sidebar's brand header, as a first-party app shows its name: the live mark in the user's
/// chosen icon style, and "Homebot".
struct SidebarBrand: View {
  @Environment(AppModel.self) private var model
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    HStack(spacing: 9) {
      LiveMark(size: 28, style: model.prefs.icon.resolved(dark: scheme == .dark))
      Text(verbatim: "Homebot")
        .font(.system(size: 17, weight: .semibold))
        .tracking(-0.2)
    }
    .padding(.horizontal, 8)
    .padding(.top, 2)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: "Homebot"))
    .accessibilityAddTraits(.isHeader)
  }
}

/// Home's headline, "Talk to your [Grok Bot icon] Grok Bot with [orb] Siri." The Grok Bot icon is
/// xAI's, unaltered and still; the orb is Homebot's own (SiriOrb). When the line doesn't fit, it
/// becomes wrapping text with Siri's SF Symbol (S10's sidebar headline).
struct Hero: View {
  let template: String
  var size: CGFloat = 20

  enum Part: Equatable {
    case text(String)
    case bot
    case siri
  }

  /// The template split at {bot} and {siri}.
  static func parts(_ s: String) -> [Part] {
    var out: [Part] = []
    var rest = Substring(s)
    while let r = rest.range(of: #"\{(bot|siri)\}"#, options: .regularExpression) {
      if r.lowerBound > rest.startIndex { out.append(.text(String(rest[..<r.lowerBound]))) }
      out.append(rest[r] == "{bot}" ? .bot : .siri)
      rest = rest[r.upperBound...]
    }
    if !rest.isEmpty { out.append(.text(String(rest))) }
    return out
  }

  /// The spoken label: the names once each, no marks.
  static func plain(_ s: String) -> String {
    s.replacingOccurrences(of: "{bot}", with: "Grok Bot").replacingOccurrences(of: "{siri}", with: "Siri")
  }

  var body: some View {
    let font = Font.system(size: size, weight: .bold)
    // A mark's baseline: its centre sits on the middle of the capitals (cap height ≈ 0.7 em).
    let lift = size * 0.35
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        ForEach(Array(Self.parts(template).enumerated()), id: \.offset) { _, part in
          switch part {
          case .text(let t): Text(t)
          case .bot:
            HStack(alignment: .firstTextBaseline, spacing: size * 0.22) {
              GrokBotAvatar(size: size * 1.1).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + lift }
              Text(verbatim: "Grok Bot")
            }
          case .siri:
            HStack(alignment: .firstTextBaseline, spacing: size * 0.22) {
              SiriOrb(size: size * 1.1).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + lift }
              Text(verbatim: "Siri")
            }
          }
        }
      }
      .fixedSize()
      wrapped.fixedSize(horizontal: false, vertical: true)
    }
    .font(font)
    .tracking(-0.2)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.plain(template))
    .accessibilityAddTraits(.isHeader)
  }

  /// The headline as text, the Siri symbol inline where the system has it.
  private var wrapped: Text {
    Self.parts(template).reduce(Text("")) { out, part in
      switch part {
      case .text(let t): return out + Text(t)
      case .bot: return out + Text("Grok\u{00A0}Bot")
      case .siri:
        // The symbol and the name never wrap apart: a word joiner and a narrow no-break space.
        return SiriSymbol.available ? out + Text(Image(systemName: "siri")) + Text("\u{2060}\u{202F}Siri") : out + Text("Siri")
      }
    }
  }
}

/// One sidebar row, sized and coloured like the system sidebar: the selection is one quiet fill
/// that slides from row to row, the symbol takes the accent colour, the text never changes weight.
struct RailItem: View {
  @Environment(AppModel.self) private var model
  let page: Page
  let title: String
  var symbol: String?
  var number: Int?
  var state: StepState?
  var count: Int?
  let ns: Namespace.ID
  let go: (Page) -> Void

  var body: some View {
    let current = model.page == page
    let open = state?.open ?? true
    Button { if open { go(page) } } label: {
      HStack(spacing: 8) {
        ZStack {
          if let number {
            Circle().fill(state?.done == true ? Theme.success : current ? Theme.primary : Theme.fill)
            if state?.done == true {
              Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white).transition(.scale)
            } else {
              Text("\(number)").font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(current ? .white : Theme.muted)
            }
          } else if let symbol {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Theme.primary)
          }
        }
        .frame(width: 20, height: 20)
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: state?.done)
        Text(title).font(.system(size: 13)).lineLimit(1)
        Spacer(minLength: 0)
        if let count, count > 0 {
          Text("\(count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted)
        }
      }
      .foregroundStyle(Theme.foreground)
      .padding(.horizontal, 8)
      .frame(height: 32)
      .contentShape(Rectangle())
      .background {
        if current {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.active)
            .matchedGeometryEffect(id: "rail-selection", in: ns)
        }
      }
    }
    .buttonStyle(.plain)
    .disabled(!open)
    .opacity(open ? 1 : 0.4)
    .glideItem(page.rawValue, in: "rail")
    .accessibilityAddTraits(current ? .isSelected : [])
  }
}

// MARK: detail

struct Detail: View {
  @Environment(AppModel.self) private var model
  let dir: CGFloat
  let go: (Page) -> Void
  /// The visible height of the canvas: a page is at least this tall, so an empty state can sit
  /// in its middle.
  @State private var visible: CGFloat = 0

  var body: some View {
    ScrollViewReader { scroll in
      ScrollView {
        content(scroll)
          .frame(minHeight: visible, alignment: .top)
      }
      .onGeometryChange(for: CGFloat.self) { $0.size.height - $0.safeAreaInsets.top - $0.safeAreaInsets.bottom } action: { visible = max(0, $0) }
      .scrollIndicators(.automatic)
      .softTopEdge()
      .defaultScrollAnchor(model.env.scrollBottom ? .bottom : nil)
    }
    .id(model.page.isStep ? "steps" : model.page.rawValue)
  }

  func content(_ scroll: ScrollViewProxy) -> some View {
    VStack(spacing: 0) {
      if model.env.dev {
        Badge(text: model.tr.devBanner, style: .info).padding(.top, 12)
      }
      // First-run notices above every page: the app runs from the wrong place, or the earlier
      // version's setup can be imported (§20.11 B1, B8).
      FirstRunNotices(go: go)
        .padding(.top, 16)
      Group {
        if model.page.isStep {
          steps
        } else {
          page(scroll)
        }
      }
      .padding(.top, model.page.isStep ? 24 : 12)
      .padding(.bottom, 48)
      .frame(maxHeight: .infinity, alignment: .top)
    }
    .frame(maxWidth: Theme.column)
    .padding(.horizontal, Theme.pagePadding)
    .frame(maxWidth: .infinity)
  }

  /// The steps sit on the canvas itself; one replaces the other with a short slide.
  var steps: some View {
    ZStack(alignment: .top) {
      ForEach([model.page], id: \.self) { p in
        stepView(p)
          .transition(Motion.transition(.asymmetric(
            insertion: .offset(x: 24 * dir).combined(with: .opacity),
            removal: .offset(x: -24 * dir).combined(with: .opacity))))
      }
    }
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder
  func stepView(_ p: Page) -> some View {
    let v = model.visit
    switch p {
    case .account: AccountStep(done: { advance(.account, visit: v) })
    case .bot: BotStep(done: { advance(.bot, visit: v) })
    case .shortcut: ShortcutStep(built: { advance(.shortcut, visit: v) })
    case .install: InstallStep(make: { go(.shortcut) })
    default: EmptyView()
    }
  }

  @ViewBuilder
  func page(_ scroll: ScrollViewProxy) -> some View {
    switch model.page {
    case .home: HomeView(go: go, scroll: scroll)
    case .shortcuts: ShortcutsView(go: go)
    case .settings: SettingsView()
    case .help: HelpView()
    default: EmptyView()
    }
  }

  /// A step's own "done" moves on only during the visit that started it: a slow build that
  /// finishes after the user left and came back must not move the newer visit on.
  func advance(_ from: Page, visit: Int) {
    guard model.page == from, model.visit == visit else { return }
    go(Flow.next(after: from, model.snapshot))
  }
}

extension View {
  /// Content fades softly under the glass toolbar on macOS 26, as in Notes, instead of the hard
  /// edge macOS draws by default; canvas and toolbar stay one surface.
  @ViewBuilder
  func softTopEdge() -> some View {
    if #available(macOS 26, *) {
      scrollEdgeEffectStyle(.soft, for: .top)
    } else {
      self
    }
  }
}

// MARK: toolbar

struct Toolbar: ToolbarContent {
  @Environment(AppModel.self) private var model
  let go: (Page) -> Void

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      Menu {
        ForEach(Lang.allCases, id: \.self) { l in
          Button { Task { await model.setLanguages(uiLang: l, announce: false) } } label: {
            if l == model.tr.lang { Label(l.info.name, systemImage: "checkmark") } else { Text(l.info.name) }
          }
        }
      } label: {
        Label(model.tr.pageLanguage, systemImage: "globe")
      }
      .help(model.tr.pageLanguage)
      Menu {
        ForEach(Appearance.allCases, id: \.self) { a in
          Button { model.setAppearance(a) } label: {
            let name = a == .system ? model.tr.themeSystem : a == .light ? model.tr.themeLight : model.tr.themeDark
            if model.prefs.appearance == a { Label(name, systemImage: "checkmark") } else { Text(name) }
          }
        }
      } label: {
        Label(model.tr.theme, systemImage: model.prefs.appearance == .dark ? "moon" : model.prefs.appearance == .light ? "sun.max" : "circle.lefthalf.filled")
      }
      .help(model.tr.theme)
    }
    // Make Shortcut on Home and the Shortcuts list, at the trailing end in a glass button of its
    // own, like the compose button in Notes.
    if model.page == .home || model.page == .shortcuts {
      if #available(macOS 26, *) {
        ToolbarSpacer(.fixed, placement: .primaryAction)
      }
      ToolbarItem(placement: .primaryAction) {
        Button { go(model.makeShortcutPage) } label: {
          Label(model.tr.build, systemImage: "plus")
        }
        .help(model.tr.build)
        .accessibilityLabel(model.tr.build)
      }
    }
  }
}

// MARK: toasts

struct ToastStack: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(spacing: 8) {
      ForEach(model.toasts) { t in
        ToastView(toast: t)
          .transition(Motion.transition(.move(edge: .bottom).combined(with: .opacity)))
      }
    }
    // A width cap for long messages; each toast inside is only as wide as its own content.
    .frame(maxWidth: ToastView.maxWidth)
    .padding(.horizontal, 20)
    .padding(.bottom, 22)
    .animation(.spring(response: 0.4, dampingFraction: 0.82), value: model.toasts)
  }
}

/// A capsule that hugs its icon and text; a long message wraps inside the stack's width cap.
struct ToastView: View {
  static let maxWidth: CGFloat = 460
  let toast: Toast
  var body: some View {
    let icon = toast.kind == .error ? "exclamationmark.circle.fill" : toast.kind == .info ? "info.circle.fill" : "checkmark.circle.fill"
    let color = toast.kind == .error ? Theme.destructive : toast.kind == .info ? Theme.primary : Theme.success
    let label = HStack(spacing: 8) {
      Image(systemName: icon).foregroundStyle(color)
      Text(toast.text).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    if #available(macOS 26, *) {
      label.glassEffect(.regular, in: Capsule())
    } else {
      label.background(.regularMaterial, in: Capsule()).shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
  }
}
