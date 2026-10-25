// The Shortcuts list (one row model: a status dot, Install and a "⋯" menu; retired ones hidden,
// S16) and Settings (languages, keep awake, open at login with the translocation refusal, page
// language, appearance).
import HomebotCore
import SwiftUI

struct ShortcutsView: View {
  @Environment(AppModel.self) private var model
  let go: (Page) -> Void

  var body: some View {
    let T = model.tr
    // Working ones and ones on their way; retired ones and never-used copies whose file is gone
    // are not shown (S16 D4).
    let live = ShortcutList.visible(model.snapshot.tokens)
    // Every Shortcut is a row of one grouped list, so all rows share one width and one set of
    // edges; the entry offer is a group of its own on the same edges.
    VStack(alignment: .leading, spacing: Theme.rowGap) {
      if live.isEmpty {
        EmptyState(title: T.emptyShortcuts, symbol: "waveform", note: T.emptyShortcutsNote) {
          Button { go(model.makeShortcutPage) } label: { Text(T.makeOne).frame(minWidth: 88) }.primaryAction()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        GroupBox {
          ForEach(live) { t in ShortcutRow(token: t, go: go) }
        }
        .animation(.snappy(duration: 0.3), value: live)
        // One phrase for all bots, offered next to the per-bot Shortcuts (§20.11).
        if !live.contains(where: { $0.mode == .entry }) && !model.snapshot.bots.isEmpty { EntryOffer() }
      }
    }
  }
}

/// "One Shortcut for all my bots": opens the Shortcut step with the entry Shortcut chosen.
struct EntryOffer: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let T = model.tr
    HStack(spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.fill)
        Image(systemName: "person.2.wave.2").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.muted)
      }
      .frame(width: 36, height: 36)
      VStack(alignment: .leading, spacing: 2) {
        Text(T.entryOffer).font(.system(size: 13, weight: .medium)).lineLimit(1)
        Text(T.entryOfferNote).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
      }
      Spacer(minLength: 8)
      Button {
        model.draft = ShortcutDraft(entry: true)
        model.go(.shortcut)
      } label: {
        Text(T.makeOne).frame(minWidth: 72)
      }
      .secondaryAction()
      .controlSize(.regular)
    }
    .padding(.horizontal, Theme.inset)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity)
    .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
  }
}

/// One Shortcut in fixed columns, the same in every row: icon | name over one line of details |
/// a status dot | Install | the actions menu. The status is the dot's colour (its words are in
/// the tooltip and for VoiceOver); "Install" is always in the same place, prominent only when the
/// Shortcut needs an update. It is also the way to another iPhone: the Install page's iPhone tab
/// always offers AirDrop and the code (S26). An action a row can't take is not in its menu.
struct ShortcutRow: View {
  @Environment(AppModel.self) private var model
  let token: TokenView
  let go: (Page) -> Void
  @State private var confirmRevoke = false
  @State private var editing = false

  var body: some View {
    let T = model.tr
    let t = token
    let status = ShortcutStatus.of(t, needsUpdate: Flow.needsUpdate(t, model.snapshot), keyUsable: model.progress[.account]?.done == true)
    HStack(spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(LinearGradient(colors: Tint.shortcut, startPoint: .top, endPoint: .bottom))
        Image(systemName: "waveform").font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
      }
      .frame(width: 36, height: 36)
      VStack(alignment: .leading, spacing: 2) {
        Text(t.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
        Text(details(t)).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle).help(made(t))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      StatusMark(status: status, label: status.label(T))
      Button { Task { await model.install(t) } } label: { Text(T.install).frame(minWidth: 56) }
        .modifier(ActionButtonStyle(prominent: status == .needsUpdate))
        .controlSize(.small)
      actions(t)
    }
    .padding(.horizontal, Theme.inset)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .alert(T.fmt(T.confirmRevoke, ["name": t.label]), isPresented: $confirmRevoke) {
      Button(T.cancel, role: .cancel) {}
      Button(T.revoke, role: .destructive) { Task { await model.revoke(t.id) } }
    } message: {
      Text("\(T.confirmRevokeBody) \(T.deleteNote)")
    }
    .sheet(isPresented: $editing) { EditBotsSheet(token: t) }
  }

  /// "homebot · English · Conversation": the bots, its language, what kind it is.
  func details(_ t: TokenView) -> String {
    let who = t.bots.map { model.snapshot.bot($0)?.name ?? $0 }.joined(separator: ", ")
    return ([who, langName(t.siriLang)] + kinds(t)).filter { !$0.isEmpty }.joined(separator: " · ")
  }

  /// When it was made, in the details' tooltip.
  func made(_ t: TokenView) -> String {
    Date(timeIntervalSince1970: t.createdAt / 1000).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(model.tr.locale))
  }

  func actions(_ t: TokenView) -> some View {
    let T = model.tr
    let entry = t.mode == .entry
    return MoreMenu(help: T.shortcutActions) {
      if t.kind == .ask {
        // The same bots in another language or kind; it replaces this one once it has answered.
        Button {
          model.draft = ShortcutDraft(bot: entry ? nil : t.bot, replaces: t.id, entry: entry, siriLang: t.siriLang, conversation: t.mode == .conversation)
          model.go(.shortcut)
        } label: { Label(T.changeLanguage, systemImage: "character.bubble") }
        if !entry {
          Button {
            model.draft = ShortcutDraft(bot: t.bot, replaces: t.id, siriLang: t.siriLang, conversation: t.mode != .conversation)
            model.go(.shortcut)
          } label: {
            Label(T.conversation, systemImage: t.mode == .conversation ? "checkmark" : "bubble.left.and.bubble.right")
          }
        }
      }
      if entry {
        Button { editing = true } label: { Label(T.editBots, systemImage: "checklist") }
      }
      Divider()
      Button(role: .destructive) { confirmRevoke = true } label: { Label(T.revoke, systemImage: "trash") }
    }
  }

  /// The labels that used to be badges: probe or lab, from the old version, one phrase for all,
  /// conversation.
  func kinds(_ t: TokenView) -> [String] {
    let T = model.tr
    var out: [String] = []
    if t.kind != .ask { out.append(t.kind == .probe ? T.kindProbe : T.kindLab) }
    if t.mode == .legacy { out.append(T.modeLegacy) }
    if t.mode == .entry { out.append(T.modeEntry) }
    if t.mode == .conversation { out.append(T.modeConversation) }
    return out
  }

  /// A Siri language's name, as in the menus; Shortcuts for an older English variant show as English.
  func langName(_ code: String) -> String { Langs.langOfSiri(code).info.name }
}

/// A row's status as a dot only: green working, orange needs an update, a grey ring while it has
/// not answered yet or waits for a key. The words are the tooltip and the accessibility label.
struct StatusMark: View {
  let status: ShortcutStatus
  let label: String
  var body: some View {
    ZStack {
      switch status {
      case .working: Circle().fill(Theme.success)
      case .needsUpdate: Circle().fill(Theme.warning)
      case .notUsedYet, .retired, .needsKey: Circle().strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 1.5)
      }
    }
    .frame(width: 9, height: 9)
    .frame(width: 20, height: 28)
    .contentShape(Rectangle())
    .help(label)
    .accessibilityElement()
    .accessibilityLabel(label)
  }
}

/// T4: which bots an entry Shortcut answers for. Saved on the Mac; the iPhone's file is unchanged.
struct EditBotsSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let token: TokenView
  @State private var picked: Set<String> = []
  @State private var saving = false

  var chosen: [String] { model.snapshot.bots.map(\.key).filter { picked.contains($0) } }

  var body: some View {
    let T = model.tr
    let s = model.snapshot
    let items = chosen.compactMap { k in s.bot(k).map { EntryChoice(key: $0.key, sessionId: $0.sessionId, name: $0.name) } }
    VStack(alignment: .leading, spacing: 14) {
      Text(T.editBots).font(.system(size: 15, weight: .semibold))
      Text(token.label).font(.system(size: 13)).foregroundStyle(Theme.muted)
      GroupBox {
        ForEach(s.bots) { b in
          let on = picked.contains(b.key)
          Row {
            Toggle(isOn: Binding(get: { on }, set: { v in if v { picked.insert(b.key) } else { picked.remove(b.key) } })) {
              Text(b.name).lineLimit(1)
            }
            .toggleStyle(.checkbox)
            .disabled(!on && picked.count >= TokenStore.maxBots)
            Spacer(minLength: 8)
            let n = chosen.firstIndex(of: b.key).map { $0 + 1 }
            Text(n.map(String.init) ?? "0")
              .font(.system(size: 11, weight: .semibold)).monospacedDigit()
              .foregroundStyle(.white)
              .frame(width: 20, height: 20)
              .background(Theme.primary, in: Circle())
              .opacity(n == nil ? 0 : 1)
          }
        }
      }
      Note(text: T.editBotsNote)
      if chosen.isEmpty { Callout(text: T.entryNone, style: .danger) }
      ForEach(Chooser.ambiguousNames(items, Langs.replyLang(token.siriLang)), id: \.self) { n in Callout(text: T.fmt(T.entryNumberOnly, ["name": n])) }
      ActionBar {
        Button(T.cancel) { dismiss() }.secondaryAction().keyboardShortcut(.cancelAction)
        Button(T.save) {
          saving = true
          Task {
            let ok = await model.setTokenBots(token.id, chosen)
            saving = false
            if ok { dismiss() }
          }
        }
        .primaryAction()
        .keyboardShortcut(.defaultAction)
        .disabled(chosen.isEmpty || saving)
      }
    }
    .padding(22)
    .frame(width: 420)
    .onAppear { picked = Set(token.bots) }
  }
}

struct SettingsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let T = model.tr
    let s = model.snapshot
    VStack(alignment: .leading, spacing: Theme.gap) {
      section(T.sectionLanguages) {
        GroupBox {
          PickerRow(label: T.defaultLang, symbol: "homepod", options: Langs.siriOptions.map { ($0.code, $0.label) }, value: Binding(
            get: { s.siriLang }, set: { v in Task { await model.setLanguages(siriLang: v) } }))
          PickerRow(label: T.phoneLang, symbol: "iphone", options: Lang.allCases.map { ($0.rawValue, $0.info.name) }, value: Binding(
            get: { s.phoneLang.rawValue }, set: { v in Task { await model.setLanguages(phoneLang: Lang(rawValue: v)) } }))
          PickerRow(label: T.pageLanguage, symbol: "globe", options: Lang.allCases.map { ($0.rawValue, $0.info.name) }, value: Binding(
            get: { T.lang.rawValue }, set: { v in Task { await model.setLanguages(uiLang: Lang(rawValue: v), announce: false) } }))
        }
        LanguageSuggestion { model.go(.install) }
      }
      section(T.sectionMac) {
        GroupBox {
          SwitchRow(title: T.startAtLogin, note: T.startAtLoginNote, symbol: "power", on: model.loginItem != .off) { v in model.setLoginItem(v) }
          SwitchRow(title: T.showMenuBar, note: T.showMenuBarNote, symbol: "menubar.rectangle", on: model.prefs.showMenuBar) { v in model.setShowMenuBar(v) }
          SwitchRow(title: T.keepAwake, note: T.keepAwakeNote, symbol: "cup.and.saucer", on: model.prefs.keepAwake) { v in Task { await model.setKeepAwake(v) } }
          // Off until turned on here; the (i) shows exactly what the last ping held.
          SwitchRow(title: T.usageShare, note: T.usageShareNote, link: (T.usageWhatsSent, privacyURL), symbol: "chart.bar", on: s.usageCounts) { v in Task { await model.setUsageCounts(v) } }
        }
        LoginItemNotes()
        if model.canImport {
          GroupBox {
            Row {
              RowIcon(symbol: "tray.and.arrow.down")
              VStack(alignment: .leading, spacing: 2) {
                Text(T.importSettings)
                Text(T.fmt(T.importSettingsNote, ["folder": model.legacyFolderName])).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
              }
              Spacer(minLength: 12)
              Button(T.importButton) { model.reviewImport() }
                .secondaryAction().controlSize(.regular).disabled(model.importing || model.offersImport)
            }
          }
        }
      }
      section(T.theme) {
        GroupBox {
          Row {
            RowIcon(symbol: "circle.lefthalf.filled")
            Text(T.theme)
            Spacer(minLength: 12)
            Picker(T.theme, selection: Binding(get: { model.prefs.appearance }, set: { model.setAppearance($0) })) {
              Text(T.themeSystem).tag(Appearance.system)
              Text(T.themeLight).tag(Appearance.light)
              Text(T.themeDark).tag(Appearance.dark)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
          }
          Row {
            RowIcon(symbol: "paintbrush")
            InlineInfo {
              Text(T.appIcon)
            } info: {
              InfoButton(label: T.appIcon, text: T.appIconNote)
            }
            Spacer(minLength: 12)
            AppIconPicker()
          }
        }
      }
      // Technical details last, as in System Settings › General › About.
      section(T.sectionAbout) {
        GroupBox {
          Row {
            RowIcon(symbol: "info.circle")
            Text(T.aboutVersion)
            Spacer(minLength: 12)
            Text(AppModel.appVersion).foregroundStyle(Theme.muted).textSelection(.enabled)
          }
          #if !HOMEBOT_MAS
          SwitchRow(title: T.updateCheck, note: T.updateCheckNote, symbol: "arrow.down.circle", on: s.updateCheck) { v in Task { await model.setUpdateCheck(v) } }
          if let u = model.update, let url = URL(string: u.url), url.scheme == "https", url.host == "homebot.fun" {
            Row {
              RowIcon(symbol: "sparkles")
              Text(T.fmt(T.updateAvailable, ["version": u.version]))
              Spacer(minLength: 12)
              Button(T.updateDownload) { NSWorkspace.shared.open(url) }.secondaryAction().controlSize(.regular)
            }
          }
          #endif
          Row {
            RowIcon(symbol: "network")
            Text(T.aboutAddress)
            Spacer(minLength: 12)
            Text(s.gatewayURL).foregroundStyle(Theme.muted).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            CopyButton(text: s.gatewayURL)
          }
        }
      }
      Note(text: model.windowNote)
      ResetRow()
    }
  }

  func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionTitle(text: title)
      content()
    }
  }
}

/// The app icon choices as thumbnails, like the Appearance swatches in System Settings: the
/// chosen one has an accent ring and a primary label; hover tints the ring only.
struct AppIconPicker: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let T = model.tr
    HStack(alignment: .top, spacing: 14) {
      ForEach(IconChoice.allCases, id: \.self) { icon in
        AppIconChoice(icon: icon, name: Self.name(icon, T), chosen: model.prefs.icon == icon) { model.setAppIcon(icon) }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(T.appIcon)
  }

  static func name(_ icon: IconChoice, _ T: Tr) -> String {
    switch icon {
    case .automatic: T.appIconAuto
    case .glow: T.appIconGlow
    case .black: T.appIconBlack
    case .white: T.appIconWhite
    }
  }
}

struct AppIconChoice: View {
  let icon: IconChoice
  let name: String
  let chosen: Bool
  let pick: () -> Void
  @State private var hover = false

  static let art: CGFloat = 48

  var body: some View {
    Button(action: pick) {
      VStack(spacing: 5) {
        // The art's canvas has the icon grid's margin; the ring sits 2 pt outside the mark.
        let mark = Self.art * 824 / 1024
        thumbnail
          .overlay(
            RoundedRectangle(cornerRadius: mark * 0.2237 + 5, style: .continuous)
              .strokeBorder(chosen ? Theme.primary : hover ? Color.primary.opacity(0.18) : .clear, lineWidth: 3)
              .frame(width: mark + 10, height: mark + 10))
        Text(name)
          .font(.system(size: 11))
          .foregroundStyle(chosen ? Theme.foreground : Theme.muted)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .accessibilityLabel(name)
    .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
  }

  /// Automatic is White on the left and Black on the right, like the Auto swatch in System Settings.
  @ViewBuilder var thumbnail: some View {
    if icon == .automatic {
      ZStack {
        IconArt(style: .black, size: Self.art)
        IconArt(style: .white, size: Self.art)
          .mask(LeftHalf())
      }
    } else {
      IconArt(style: icon.resolved(dark: false), size: Self.art)
    }
  }
}

/// The left half of a rectangle.
struct LeftHalf: Shape {
  func path(in r: CGRect) -> Path {
    Path(CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height))
  }
}

/// A settings switch with its icon column; its note is behind (i).
/// The website's privacy page: it lists every field Share anonymous analytics sends.
let privacyURL = URL(string: "https://homebot.fun/privacy")!

struct SwitchRow: View {
  let title: String
  let note: String
  var link: (title: String, url: URL)? = nil
  let symbol: String
  let on: Bool
  let set: (Bool) -> Void

  var body: some View {
    Row {
      RowIcon(symbol: symbol)
      InlineInfo {
        Text(title)
      } info: {
        InfoButton(label: title, text: note, link: link)
      }
      Spacer(minLength: 12)
      Toggle(title, isOn: Binding(get: { on }, set: set)).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }
  }
}

/// Copies a value; the symbol turns into a check for a moment (same size, colour only).
struct CopyButton: View {
  @Environment(AppModel.self) private var model
  let text: String
  @State private var copied = false

  var body: some View {
    let T = model.tr
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      copied = true
      Task {
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        copied = false
      }
    } label: {
      Image(systemName: copied ? "checkmark" : "doc.on.doc")
        .foregroundStyle(copied ? Color.green : Theme.muted)
        .frame(width: 18, height: 18)
        .contentTransition(.symbolEffect(.replace))
    }
    .buttonStyle(.borderless)
    .help(copied ? T.copied : T.copy)
    .accessibilityLabel(copied ? T.copied : T.copy)
  }
}
