// Small pieces shared by every view, in the system's own idiom: inset grouped sections with
// label-left, control-right rows (System Settings), Liquid Glass buttons on macOS 26 with the
// bordered styles before, semantic colours. Steadiness rules (DECISIONS item 22): hover, focus and
// selection change colour only, never font weight, size or scale; every block in a view spans the
// same column edges.
import SwiftUI

// MARK: layout

/// The app-icon tile and title that open each step, centred on the canvas like a setup assistant.
struct StepHeader<Accessory: View>: View {
  let symbol: String
  let tint: [Color]
  let title: String
  @ViewBuilder var accessory: Accessory
  @State private var shown = false
  @Environment(\.accessibilityReduceMotion) private var reduce

  init(symbol: String, tint: [Color], title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
    self.symbol = symbol
    self.tint = tint
    self.title = title
    self.accessory = accessory()
  }

  var body: some View {
    VStack(spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(LinearGradient(colors: tint, startPoint: .top, endPoint: .bottom))
          .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
        Image(systemName: symbol).font(.system(size: 25, weight: .semibold)).foregroundStyle(.white)
      }
      .frame(width: 58, height: 58)
      .scaleEffect(shown || reduce ? 1 : 0.6)
      .opacity(shown || reduce ? 1 : 0)
      .accessibilityHidden(true)
      Text(title)
        .font(.system(size: 24, weight: .bold))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      accessory
    }
    .frame(maxWidth: .infinity)
    .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { shown = true } }
  }
}

/// A section title above a group, as System Settings sets them.
struct SectionTitle<Accessory: View>: View {
  let text: String
  /// An (i) or (?) right after the title (InlineInfo).
  @ViewBuilder var accessory: Accessory

  var body: some View {
    InlineInfo {
      Text(text)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Theme.foreground)
        .accessibilityAddTraits(.isHeader)
    } info: {
      accessory
    }
    .padding(.horizontal, Theme.inset)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension SectionTitle where Accessory == EmptyView {
  init(text: String) {
    self.init(text: text) { EmptyView() }
  }
}

/// A small grey label above a control.
struct FieldLabel: View {
  let text: String
  var symbol: String?
  var body: some View {
    HStack(spacing: 5) {
      if let symbol { Image(systemName: symbol).imageScale(.small) }
      Text(text)
    }
    .font(.system(size: 12, weight: .medium))
    .foregroundStyle(Theme.muted)
    .padding(.horizontal, Theme.inset)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// One line of quiet supporting text, under a group (the group's footer).
struct Note: View {
  let text: String
  var body: some View {
    Text(text)
      .font(.system(size: 12))
      .foregroundStyle(Theme.muted)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, Theme.inset)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// An inset grouped section, like System Settings: rows separated by hairlines on one rounded fill.
struct GroupBox<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    VStack(spacing: 0) {
      Group(subviews: content) { rows in
        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
          if i > 0 { Divider().padding(.horizontal, Theme.inset) }
          row
        }
      }
    }
    .frame(maxWidth: .infinity)
    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
  }
}

/// One row of a group: content on one line, the control at the trailing edge.
struct Row<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    HStack(spacing: 10) { content }
      .font(.system(size: 13))
      .padding(.horizontal, Theme.inset)
      .padding(.vertical, 8)
      .frame(minHeight: 40)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The symbol column at a row's leading edge, the same width in every row so titles line up.
struct RowIcon: View {
  let symbol: String
  var color: Color = Theme.muted
  var body: some View {
    Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(color).frame(width: 20)
  }
}

extension Theme {
  /// A row's leading and trailing inset; notes and section titles use it too, so text in and
  /// around a group starts on one edge.
  static let inset: CGFloat = 12
}

// MARK: badges and alerts

enum BadgeStyle {
  case success, danger, neutral, warning, info

  /// Text colours dark enough to read on their own tint in light mode.
  var fg: Color {
    switch self {
    case .success: Color.dynamic(0x248a3d, 0x30d158)
    case .danger: Theme.destructive
    case .neutral: Theme.muted
    case .warning: Color.dynamic(0xb25000, 0xffb340)
    case .info: Theme.primary
    }
  }
}

struct Badge: View {
  let text: String
  var style: BadgeStyle = .neutral
  var dot = false
  var body: some View {
    HStack(spacing: 5) {
      if dot { Circle().fill(style.fg).frame(width: 6, height: 6) }
      Text(text).lineLimit(1)
    }
    .font(.system(size: 11, weight: .medium))
    .foregroundStyle(style.fg)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(style.fg.opacity(0.12), in: Capsule())
    .fixedSize()
  }
}

/// A status as the system lists show it: a coloured dot and the state in secondary text.
struct StatusDot: View {
  let text: String
  /// true: fine, false: a problem, nil: nothing to judge (a grey dot, so states line up).
  let ok: Bool?
  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(ok.map { $0 ? Theme.success : Theme.warning } ?? Color(nsColor: .tertiaryLabelColor)).frame(width: 7, height: 7)
      Text(text).foregroundStyle(Theme.muted).lineLimit(1)
    }
    .font(.system(size: 12))
    .fixedSize()
  }
}

/// A warning or error block with its icon (beUI Alert).
struct Callout<Accessory: View>: View {
  let text: String
  var style: BadgeStyle = .warning
  /// A bold first line above the text.
  var title: String?
  @ViewBuilder var accessory: Accessory

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: style == .danger ? "exclamationmark.circle.fill" : style == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
        .font(.system(size: 14))
        .foregroundStyle(style == .warning ? Theme.warning : style.fg)
      VStack(alignment: .leading, spacing: 3) {
        if let title { Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.foreground).fixedSize(horizontal: false, vertical: true) }
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.foreground).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
      accessory
    }
    .padding(.horizontal, Theme.inset)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background((style == .warning ? Theme.warning : style.fg).opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
  }
}

extension Callout where Accessory == EmptyView {
  init(text: String, style: BadgeStyle = .warning, title: String? = nil) {
    self.init(text: text, style: style, title: title) { EmptyView() }
  }
}

// MARK: gliding hover

/// Frames of hoverable items in their container, by id.
struct ItemFrames: PreferenceKey {
  static let defaultValue: [String: CGRect] = [:]
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

extension View {
  /// Marks a view as one item of the enclosing `GlideHover`.
  func glideItem(_ id: String, in space: String) -> some View {
    background(GeometryReader { g in Color.clear.preference(key: ItemFrames.self, value: [id: g.frame(in: .named(space))]) })
  }
}

/// One highlight glides to the item under the pointer (Fluid Functionalism's fluid hover, as on
/// the page's step rail and chips). Colour only: the items never move or resize. Quick enough to
/// keep up with the pointer, settled without overshoot.
struct GlideHover<Content: View>: View {
  let space: String
  var radius: CGFloat = 8
  var disabled: Set<String> = []
  @ViewBuilder var content: Content
  @State private var frames: [String: CGRect] = [:]
  @State private var hovered: String?
  @Environment(\.accessibilityReduceMotion) private var reduce

  var body: some View {
    content
      .coordinateSpace(.named(space))
      .onPreferenceChange(ItemFrames.self) { frames = $0 }
      .onContinuousHover(coordinateSpace: .named(space)) { phase in
        switch phase {
        case .active(let p):
          let hit = frames.first { !disabled.contains($0.key) && $0.value.insetBy(dx: 0, dy: -1).contains(p) }?.key
          if hit != hovered { hovered = hit }
        case .ended:
          hovered = nil
        }
      }
      .background(alignment: .topLeading) {
        if let h = hovered, let r = frames[h] {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.hover)
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
            .transition(.opacity)
        }
      }
      .animation(reduce ? nil : .snappy(duration: 0.16), value: hovered)
  }
}

// MARK: controls

/// A text field as a grouped-form row: the label at the leading edge, the entry filling the rest.
/// The entry is leading-aligned: a right-aligned NSTextField doesn't draw trailing spaces, so a
/// typed space stayed invisible until the next word (Felix, S12). The field shows exactly what was
/// typed; trimming and other normalisation happen only where the value is checked or used.
struct Field: View {
  let label: String
  @Binding var text: String
  var placeholder = ""
  var symbol: String?
  var secure = false
  var mono = false
  var state: FieldState = .normal
  var maxLength = 200
  var onSubmit: () -> Void = {}
  @FocusState private var focused: Bool

  enum FieldState { case normal, error, success }

  /// The text cut to `max` characters, or nil when it fits (then the field keeps it untouched).
  static func clamped(_ text: String, _ max: Int) -> String? {
    text.count > max ? String(text.prefix(max)) : nil
  }

  var body: some View {
    Row {
      if let symbol { RowIcon(symbol: symbol, color: state == .error ? Theme.destructive : Theme.muted) }
      if !label.isEmpty {
        Text(label)
          .foregroundStyle(state == .error ? Theme.destructive : Theme.foreground)
          .lineLimit(1)
          .fixedSize()
      }
      Group {
        if secure {
          SecureField(label.isEmpty ? placeholder : label, text: $text, prompt: Text(placeholder))
        } else {
          TextField(label.isEmpty ? placeholder : label, text: $text, prompt: Text(placeholder))
        }
      }
      .labelsHidden()
      .textFieldStyle(.plain)
      .multilineTextAlignment(.leading)
      .font(mono ? .system(size: 13, design: .monospaced) : .system(size: 13))
      .autocorrectionDisabled()
      .focused($focused)
      .onSubmit(onSubmit)
      .onChange(of: text) { _, v in if let c = Field.clamped(v, maxLength) { text = c } }
      .frame(maxWidth: .infinity)
      // Always laid out, so the entry never moves when the state changes: only its colour does.
      Image(systemName: state == .error ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
        .foregroundStyle(state == .error ? Theme.destructive : Theme.success)
        .opacity(state == .normal ? 0 : 1)
        .accessibilityHidden(state == .normal)
    }
    // The focused row is marked by the accent colour along its edge, like a focus ring.
    .overlay(
      RoundedRectangle(cornerRadius: Theme.radius - 2, style: .continuous)
        .strokeBorder(Theme.primary.opacity(focused ? 0.55 : 0), lineWidth: 2)
        .padding(2)
        .allowsHitTesting(false))
    .contentShape(Rectangle())
    .onTapGesture { focused = true }
    .animation(.easeOut(duration: 0.12), value: focused)
    .animation(.easeOut(duration: 0.15), value: state)
  }
}

/// A menu picker as a grouped-form row: the label at the leading edge, the menu at the trailing one.
struct PickerRow: View {
  let label: String
  var symbol: String?
  /// What the setting controls, behind an (i) right after the label.
  var info: String? = nil
  let options: [(value: String, label: String)]
  @Binding var value: String

  var body: some View {
    Row {
      if let symbol { RowIcon(symbol: symbol) }
      InlineInfo {
        Text(label).lineLimit(1)
      } info: {
        if let info { InfoButton(label: label, text: info) }
      }
      .layoutPriority(1)
      Spacer(minLength: 12)
      // The menu takes its natural width but gives way (its title truncates) before a long
      // value, such as a 60-character bot name, can push the row past the column.
      Picker(label, selection: $value) {
        ForEach(options, id: \.value) { o in Text(o.label).tag(o.value) }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// A row that folds content open below it, with the system's disclosure chevron. The header is a
/// grouped row of its own; hover changes its fill only.
struct Disclosure<Content: View>: View {
  let title: String
  @Binding var open: Bool
  @ViewBuilder var content: Content
  @State private var hover = false

  var body: some View {
    VStack(spacing: 0) {
      Button {
        withAnimation(Motion.reduced ? .easeOut(duration: 0.15) : .snappy(duration: 0.28)) { open.toggle() }
      } label: {
        HStack(spacing: 10) {
          Text(title).font(.system(size: 13))
          Spacer()
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.muted)
            .rotationEffect(.degrees(open ? 90 : 0))
        }
        .foregroundStyle(Theme.foreground)
        .padding(.horizontal, Theme.inset)
        .frame(height: 40)
        .contentShape(Rectangle())
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .background(hover ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
      }
      .buttonStyle(.plain)
      .onHover { hover = $0 }
      .accessibilityValue(open ? "expanded" : "collapsed")
      if open {
        content
          .padding(.top, Theme.rowGap)
          .transition(Motion.transition(.opacity.combined(with: .move(edge: .top))))
      }
    }
    .clipped()
  }
}

/// Primary and secondary buttons: Liquid Glass on macOS 26 (prominent glass in the user's accent
/// colour), the bordered system styles before.
/// An empty list or log, as first-party apps show one: the system's ContentUnavailableView (a
/// symbol, a title, an optional line and the way out). On a page of its own it is centred in the
/// canvas (`Detail` makes the canvas at least as tall as the window).
struct EmptyState<Actions: View>: View {
  let title: String
  let symbol: String
  var note: String?
  @ViewBuilder var actions: () -> Actions

  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: symbol)
    } description: {
      if let note { Text(note) }
    } actions: {
      actions()
    }
  }
}

extension EmptyState where Actions == EmptyView {
  init(title: String, symbol: String, note: String? = nil) {
    self.init(title: title, symbol: symbol, note: note) { EmptyView() }
  }
}

struct ActionButtonStyle: ViewModifier {
  var prominent: Bool
  var destructive = false
  var tint: Color? { destructive ? Theme.destructive : nil }

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      if prominent {
        content.buttonStyle(.glassProminent).tint(tint)
      } else {
        content.buttonStyle(.glass)
      }
    } else {
      if prominent {
        content.buttonStyle(.borderedProminent).tint(tint)
      } else {
        content.buttonStyle(.bordered)
      }
    }
  }
}

extension View {
  func primaryAction(destructive: Bool = false) -> some View {
    modifier(ActionButtonStyle(prominent: true, destructive: destructive)).controlSize(.large)
  }
  func secondaryAction() -> some View { modifier(ActionButtonStyle(prominent: false)).controlSize(.large) }

  /// Buttons that sit next to each other share one Liquid Glass layer on macOS 26, so they read
  /// and morph as one group.
  @ViewBuilder
  func glassGroup(spacing: CGFloat = 8) -> some View {
    if #available(macOS 26, *) {
      GlassEffectContainer(spacing: spacing) { self }
    } else {
      self
    }
  }
}

/// A step's buttons: secondary ones first, the main one last at the trailing edge (the system's
/// dialog and assistant order).
struct ActionBar<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    HStack(spacing: 8) { content }
      .frame(maxWidth: .infinity, alignment: .trailing)
      .glassGroup()
  }
}

/// A button whose label shows progress, then success, then returns (beUI StatefulButton). The
/// label keeps one width for every state, so nothing next to it moves.
struct StatefulButton: View {
  enum Phase: Equatable { case idle, busy, done, failed }
  let title: String
  var busyTitle: String?
  var doneTitle: String?
  var failedTitle: String?
  @Binding var phase: Phase
  var prominent = true
  var minWidth: CGFloat = 96
  var disabled = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        // Every label is laid out (hidden) so the widest one sets the width.
        ForEach([title, busyTitle, doneTitle, failedTitle].compactMap { $0 }, id: \.self) { Text($0).hidden() }
        HStack(spacing: 6) {
          switch phase {
          case .busy: ProgressView().controlSize(.small)
          case .done: Image(systemName: "checkmark").fontWeight(.semibold)
          default: EmptyView()
          }
          Text(label)
        }
      }
      .frame(minWidth: minWidth)
    }
    .disabled(disabled || phase == .busy)
    .modifier(ActionButtonStyle(prominent: prominent))
    .controlSize(.large)
    .animation(.easeOut(duration: 0.2), value: phase)
  }

  var label: String {
    switch phase {
    case .idle: title
    case .busy: busyTitle ?? title
    case .done: doneTitle ?? title
    case .failed: failedTitle ?? title
    }
  }
}

/// Phrase suggestions as chips; the hover glides between them.
struct Chips: View {
  let label: String
  let items: [String]
  let pick: (String) -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.leading, Theme.inset)
      GlideHover(space: "chips", radius: 13) {
        FlowLayout(spacing: 6) {
          ForEach(items, id: \.self) { item in
            Button { pick(item) } label: {
              Text(item)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glideItem(item, in: "chips")
          }
        }
      }
      Spacer(minLength: 0)
    }
  }
}

/// Lays children out in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
  var spacing: CGFloat = 6
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var row: CGFloat = 0
    var widest: CGFloat = 0
    for s in subviews {
      let size = s.sizeThatFits(.unspecified)
      if x > 0 && x + size.width > width {
        y += row + spacing
        x = 0
        row = 0
      }
      x += size.width + spacing
      row = max(row, size.height)
      widest = max(widest, x - spacing)
    }
    return CGSize(width: proposal.width ?? widest, height: y + row)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    var y = bounds.minY
    var row: CGFloat = 0
    for s in subviews {
      let size = s.sizeThatFits(.unspecified)
      if x > bounds.minX && x + size.width > bounds.maxX {
        y += row + spacing
        x = bounds.minX
        row = 0
      }
      s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      row = max(row, size.height)
    }
  }
}

/// A round icon button with colour-only hover (trash, folder, pencil).
struct IconButton: View {
  let symbol: String
  let help: String
  var destructiveHover = false
  let action: () -> Void
  @State private var hover = false

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 13))
        .foregroundStyle(hover ? (destructiveHover ? Theme.destructive : Theme.foreground) : Theme.muted)
        .frame(width: 28, height: 28)
        .background(hover ? Theme.hover : .clear, in: Circle())
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .help(help)
    .accessibilityLabel(help)
  }
}

/// A row's "⋯" actions menu, the size of an IconButton; hover tints its circle (colour only).
struct MoreMenu<Items: View>: View {
  let help: String
  @ViewBuilder var items: Items
  @State private var hover = false

  var body: some View {
    Menu { items } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(hover ? Theme.foreground : Theme.muted)
        .frame(width: 28, height: 28)
        .background(hover ? Theme.hover : .clear, in: Circle())
        .contentShape(Circle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .onHover { hover = $0 }
    .help(help)
    .accessibilityLabel(help)
  }
}

/// A link-styled button in the accent colour; hover underlines it (colour and line only).
struct QuietLink: View {
  let title: String
  var symbol: String?
  let action: () -> Void
  @State private var hover = false
  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Text(title)
        if let symbol { Image(systemName: symbol).imageScale(.small) }
      }
      .font(.system(size: 13))
      .foregroundStyle(Theme.primary)
      .underline(hover)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
  }
}
