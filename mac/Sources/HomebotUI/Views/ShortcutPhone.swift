// Setup steps 3 and 4 (web/src/app/steps/make.tsx, phone.tsx): the live "Hey Siri, …" exchange
// preview, phrase chips, problems inline, the "Sign with Apple" consent switch and options; then
// Install (S16): on this Mac (iCloud brings it to the iPhone) or to the iPhone by AirDrop (Show
// in Finder) or a one-time QR link, with the steps in the iPhone's language.
import AppKit
import HomebotCore
import SwiftUI

struct ShortcutStep: View {
  @Environment(AppModel.self) private var model
  let built: () -> Void

  @State private var bot = ""
  /// One phrase for several bots (DESIGN §20.5), offered next to the per-bot Shortcut.
  @State private var entry = false
  /// The entry Shortcut's bots; nil until the user changes it (then: every bot, up to 9).
  @State private var picked: Set<String>?
  @State private var name = ""
  /// This Shortcut's language; nil: the default language (Settings).
  @State private var lang: String?
  /// Keep listening after each answer (DESIGN §18): opt-in, per-bot Shortcuts only.
  @State private var conversation = false
  @State private var url = ""
  /// nil: the default (replace the bot's working Shortcut); "": replace nothing.
  @State private var replaces: String?
  @State private var preview: (key: String, value: ShortcutPreview)?
  @State private var previewError: String?
  @State private var phase: StatefulButton.Phase = .idle
  @State private var optionsOpen = false
  /// A flip counts at once: Make sends what the switch shows, even before the save returns.

  /// The entry Shortcut's bots in menu order: the order of the bot list.
  var chosen: [String] {
    let all = model.snapshot.bots.map(\.key)
    guard let picked else { return Array(all.prefix(TokenStore.maxBots)) }
    return all.filter { picked.contains($0) }
  }

  var input: ShortcutInput {
    let s = model.snapshot
    if entry {
      return ShortcutInput(bot: "", name: name.isEmpty ? nil : name, url: url.isEmpty ? nil : url,
                           replaces: Flow.defaultReplaces(s, entryBots: chosen, requested: replaces), entry: true, bots: chosen, siriLang: lang)
    }
    return ShortcutInput(bot: bot, name: name.isEmpty ? nil : name, url: url.isEmpty ? nil : url,
                         replaces: Flow.defaultReplaces(s, bot: bot, requested: replaces), siriLang: lang, conversation: conversation)
  }

  /// Token states and labels are part of the key: a revoke elsewhere can free a phrase.
  var key: String {
    let s = model.snapshot
    let what: String = entry ? "entry:" + chosen.joined(separator: ",") : bot
    let bots: String = s.bots.map { (b: BotView) -> String in b.key + "=" + b.name }.joined()
    let tokens: String = s.tokens.map { (t: TokenView) -> String in t.id + t.state.rawValue + t.label + t.bots.joined(separator: ",") }.joined()
    let parts: [String] = [what, name, url, input.replaces ?? "-", lang ?? s.siriLang, s.phoneLang.rawValue, model.tr.lang.rawValue, bots, tokens]
    return parts.joined(separator: "|")
  }

  var body: some View {
    let T = model.tr
    let s = model.snapshot
    let shown = preview?.value
    let current = preview?.key == key
    let usable = entry ? Flow.replaceable(s, entryBots: chosen) : Flow.replaceable(s, bot: bot)
    VStack(spacing: Theme.gap) {
      StepHeader(symbol: "sparkles", tint: Tint.shortcut, title: T.shortcutTitle)
      Picker(T.shortcutTitle, selection: Binding(get: { entry }, set: { v in
        entry = v
        name = ""
        replaces = nil
      })) {
        Text(T.kindOne).tag(false)
        Text(T.kindAll).tag(true)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      ExchangePreview(lines: shown?.exchange ?? [])
      VStack(spacing: 8) {
        if entry {
          Callout(text: T.entryUntested, style: .info)
          VStack(spacing: 8) {
            SectionTitle(text: T.entryBots)
            GroupBox {
              ForEach(s.bots) { b in botRow(b) }
            }
            Note(text: T.entryBotsNote)
          }
          .padding(.bottom, 4)
          if chosen.isEmpty { Callout(text: T.entryNone, style: .danger) }
          ForEach(shown?.numberOnly ?? [], id: \.self) { n in Callout(text: T.fmt(T.entryNumberOnly, ["name": n])) }
        }
        GroupBox {
          if !entry && s.bots.count > 1 {
            PickerRow(label: T.bot, symbol: "sparkle.magnifyingglass", options: s.bots.map { ($0.key, $0.name) }, value: Binding(get: { bot }, set: { v in
              bot = v
              name = ""
              replaces = nil
            }))
          }
          Field(label: T.phrase, text: $name, placeholder: shown?.name ?? "", symbol: "mic", state: shown?.blocking == true ? .error : .normal, maxLength: 60) {
            // Return never consents: only the button that says it signs with Apple does.
            if canMake(current) && s.appleSigning { make() }
          }
          // Each Shortcut keeps its own language; it starts as the default one.
          PickerRow(label: T.shortcutLang, symbol: "character.bubble", options: Langs.siriOptions.map { ($0.code, $0.label) }, value: Binding(
            get: { lang ?? s.siriLang }, set: { v in
              lang = v == s.siriLang ? nil : v
              name = ""
            }))
          if !entry {
            Row {
              RowIcon(symbol: "bubble.left.and.bubble.right")
              VStack(alignment: .leading, spacing: 2) {
                Text(T.conversation)
                Text(T.fmt(T.conversationNote, ["word": Conversation.endWord(Langs.replyLang(lang ?? s.siriLang))]))
                  .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
              }
              Spacer(minLength: 8)
              Toggle(T.conversation, isOn: $conversation)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
          }
        }
        // Refused: red. Advice: one short line, with the first alternative one click away.
        ForEach((shown?.problems ?? []).filter(\.blocking)) { p in Callout(text: p.text, style: .danger) }
        if let shown, let advice = shown.problems.first(where: { !$0.blocking }) {
          PhraseHint(text: hint(advice.code), alternative: shown.alternatives.first) { name = $0 }
        } else if let shown, !shown.alternatives.isEmpty {
          Chips(label: T.alternatives, items: shown.alternatives) { name = $0 }
        }
        if let previewError { Callout(text: previewError, style: .danger) }
      }
      Disclosure(title: T.more, open: $optionsOpen) {
        VStack(spacing: 8) {
          GroupBox {
            if !usable.isEmpty {
              PickerRow(label: T.replaces, options: [("none", T.replacesNone)] + usable.map { ($0.id, "\($0.label) · \(stateLabel($0))") },
                        value: Binding(get: { input.replaces ?? "none" }, set: { replaces = $0 == "none" ? "" : $0 }))
            }
            Field(label: T.gatewayUrl, text: $url, placeholder: s.gatewayURL, mono: true, maxLength: 200)
          }
          if !usable.isEmpty { Note(text: T.replacesNoteAnswered) }
        }
      }
      // Without consent, the button says that it signs with Apple, and the line under it says
      // what that sends (DECISIONS item 24); clicking it is the consent.
      VStack(alignment: .trailing, spacing: 8) {
        ActionBar {
          StatefulButton(title: s.appleSigning ? T.build : T.signAndMake, busyTitle: T.building, doneTitle: T.built, failedTitle: s.appleSigning ? T.retry : T.signAndMake, phase: $phase, minWidth: 150, disabled: !canMake(current)) { make() }
        }
        if !s.appleSigning { SignConsentNote() }
      }
    }
    .onAppear(perform: syncBot)
    .onChange(of: model.snapshot.bots) { syncBot() }
    .task(id: key) { await loadPreview() }
  }

  /// One bot of the entry set: a checkbox, and its number in Siri's menu when it is in the set.
  func botRow(_ b: BotView) -> some View {
    let on = chosen.contains(b.key)
    let number = chosen.firstIndex(of: b.key).map { $0 + 1 }
    let full = !on && chosen.count >= TokenStore.maxBots
    return Row {
      Toggle(isOn: Binding(get: { on }, set: { v in
        var set = Set(chosen)
        if v { set.insert(b.key) } else { set.remove(b.key) }
        picked = set
        replaces = nil
      })) {
        Text(b.name).lineLimit(1)
      }
      .toggleStyle(.checkbox)
      .disabled(full)
      Spacer(minLength: 8)
      // Always laid out, so ticking a bot never moves the row: only its colour changes.
      Text(number.map(String.init) ?? "0")
        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
        .foregroundStyle(.white)
        .frame(width: 20, height: 20)
        .background(Theme.primary, in: Circle())
        .opacity(number == nil ? 0 : 1)
        .accessibilityHidden(number == nil)
    }
  }

  /// The short line for a phrase problem that is only advice.
  func hint(_ code: String) -> String {
    let T = model.tr
    switch code {
    case PhraseProblem.Code.wrongScript.rawValue: return T.hintScript
    case PhraseProblem.Code.badStart.rawValue: return T.hintStart
    default: return T.hintOther
    }
  }

  func stateLabel(_ t: TokenView) -> String {
    switch t.state {
    case .pending: t.waitingForAnswer ? model.tr.stateTrying : model.tr.statePending
    case .active: model.tr.stateActive
    case .retired: model.tr.stateRetired
    }
  }

  func canMake(_ current: Bool) -> Bool {
    (entry ? !chosen.isEmpty : !bot.isEmpty) && current && preview?.value.blocking == false && previewError == nil && phase != .busy
  }

  /// A Shortcut step opened from the Shortcuts list; else keep the chosen bot valid.
  func syncBot() {
    if let d = model.draft {
      entry = d.entry
      if let b = d.bot { bot = b }
      lang = d.siriLang.flatMap { $0 == model.snapshot.siriLang ? nil : $0 }
      conversation = d.conversation
      name = ""
      replaces = d.replaces
      model.draft = nil
    }
    if !model.snapshot.bots.contains(where: { $0.key == bot }) { bot = model.snapshot.bots.first?.key ?? "" }
    if let p = picked { picked = p.intersection(model.snapshot.bots.map(\.key)) }
  }

  /// Live preview, lightly debounced while typing; the first one goes out at once.
  func loadPreview() async {
    guard entry ? !chosen.isEmpty : !bot.isEmpty else {
      preview = nil
      return
    }
    if preview != nil { try? await Task.sleep(nanoseconds: 180_000_000) }
    if Task.isCancelled { return }
    let k = key
    do {
      let p = try await model.preview(input)
      if Task.isCancelled || k != key { return }
      withAnimation(.easeOut(duration: 0.25)) { preview = (k, p) }
      previewError = nil
    } catch {
      if Task.isCancelled { return }
      preview = nil
      previewError = model.message(error)
    }
  }

  func make() {
    phase = .busy
    Task {
      guard let _ = await model.signAndMake(input) else {
        phase = .failed
        return
      }
      phase = .done
      name = ""
      lang = nil
      conversation = false
      replaces = nil
      try? await Task.sleep(nanoseconds: 650_000_000)
      phase = .idle
      built()
    }
  }
}

/// Advice about the phrase: one quiet line, and "Use <alternative>" when there is one.
struct PhraseHint: View {
  @Environment(AppModel.self) private var model
  let text: String
  let alternative: String?
  let use: (String) -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "lightbulb").foregroundStyle(Theme.warning)
      Text(text).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      if let alternative {
        Button(model.tr.fmt(model.tr.useName, ["name": alternative])) { use(alternative) }
          .secondaryAction()
          .controlSize(.small)
      }
    }
    .font(.system(size: 12))
    .padding(.horizontal, Theme.inset)
  }
}

/// The conversation the Shortcut makes possible: the user's words in blue bubbles on the right,
/// Siri's lines next to the orb (SiriOrb, Homebot's own drawing) on the left, on a plain dark
/// card. The entry Shortcut's preview includes the "which bot?" turn.
struct ExchangePreview: View {
  let lines: [EntryPreview.Line]

  var body: some View {
    ZStack(alignment: .bottom) {
      LinearGradient(colors: [.hex(0x18181b), .black], startPoint: .top, endPoint: .bottom)
      VStack(spacing: 14) {
        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
          if line.user { user(line.text, first: i == 0) } else { siri(line.text) }
        }
      }
      .padding(26)
      // Sized for two bubbles, so the card does not grow when the first preview lands.
      .frame(minHeight: 150, alignment: .bottom)
      .animation(.easeOut(duration: 0.25), value: lines)
    }
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    .environment(\.colorScheme, .dark)
    .accessibilityElement(children: .combine)
  }

  /// The opening "Hey Siri, …" is the large line; later answers are the size of Siri's.
  func user(_ text: String, first: Bool) -> some View {
    HStack {
      Spacer(minLength: 40)
      Text(text)
        .font(.system(size: first ? 20 : 16, weight: first ? .medium : .regular))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.hex(0x0a84ff), in: UnevenRoundedRectangle(topLeadingRadius: 21, bottomLeadingRadius: 21, bottomTrailingRadius: 6, topTrailingRadius: 21, style: .continuous))
        .id(text)
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
    }
  }

  func siri(_ text: String) -> some View {
    HStack(alignment: .bottom, spacing: 8) {
      SiriOrb(size: 28)
      Text(text)
        .font(.system(size: 16))
        .foregroundStyle(.white.opacity(0.9))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.12), in: UnevenRoundedRectangle(topLeadingRadius: 21, bottomLeadingRadius: 6, bottomTrailingRadius: 21, topTrailingRadius: 21, style: .continuous))
        .id(text)
        .transition(.opacity.combined(with: .offset(y: 6)))
      Spacer(minLength: 40)
    }
  }
}

/// Setup step 4, Install (S16): the Shortcut goes to this Mac, from which iCloud brings it to the
/// iPhone (same Apple Account), or straight to the iPhone by AirDrop or a code. The first visit
/// asks which; then a segmented switch keeps the choice in view.
struct InstallStep: View {
  @Environment(AppModel.self) private var model
  let make: () -> Void
  @State private var link: DownloadLink?
  @State private var linking = false

  var body: some View {
    Group {
      if let build = model.build {
        ready(build)
      } else {
        empty
      }
    }
    .onChange(of: model.build?.tokenId) { link = nil }
  }

  var empty: some View {
    let T = model.tr
    // Made on an earlier visit and not installed yet: install it; else make one first.
    let waiting = ShortcutList.visible(model.snapshot.tokens).first { $0.kind == .ask && $0.state == .pending }
    return VStack(spacing: Theme.gap) {
      StepHeader(symbol: "square.and.arrow.down", tint: Tint.phone, title: T.install)
      if let w = waiting {
        Button { Task { await model.install(w) } } label: { Text(T.fmt(T.installTitle, ["name": w.label])).frame(minWidth: 88) }.primaryAction()
      } else {
        // The line and its button as one pair, spaced like the Shortcuts page's empty state.
        VStack(spacing: 12) {
          Text(T.installNone).font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
          Button(action: make) { Text(T.makeOne).frame(minWidth: 88) }.primaryAction()
        }
      }
    }
    .padding(.bottom, 12)
  }

  func ready(_ build: ShortcutBuild) -> some View {
    let T = model.tr
    return VStack(spacing: Theme.gap) {
      StepHeader(symbol: "square.and.arrow.down", tint: Tint.phone, title: T.fmt(T.installTitle, ["name": build.name]))
      // Several made at once (language replacements): one at a time, each with its own file.
      if model.batch.count > 1 {
        VStack(spacing: 8) {
          Picker(T.install, selection: Binding(get: { build.tokenId }, set: { id in
            if let b = model.batch.first(where: { $0.tokenId == id }) { model.build = b }
          })) {
            ForEach(model.batch, id: \.tokenId) { Text($0.name).tag($0.tokenId) }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
          Note(text: T.fmt(T.phoneBatch, ["n": "\(model.batch.count)"]))
        }
      }
      if let target = model.prefs.installTarget {
        Picker(T.install, selection: Binding(get: { target }, set: { t in withAnimation(Motion.snappy) { model.setInstallTarget(t) } })) {
          Text(T.installMac).tag(InstallTarget.mac)
          Text(T.installPhone).tag(InstallTarget.iphone)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        Group {
          if target == .mac {
            MacInstall(build: build)
          } else {
            phone(build)
          }
        }
        .transition(.opacity)
      } else {
        question
      }
    }
  }

  /// The one question a novice can answer: the same Apple Account or not.
  var question: some View {
    let T = model.tr
    return VStack(spacing: 14) {
      Text(T.installAsk).font(.system(size: 15, weight: .medium)).multilineTextAlignment(.center)
      HStack(spacing: 12) {
        DeliveryCard(symbol: "macbook.and.iphone", tint: Color(nsColor: .systemBlue), title: T.installSame, note: T.installSameNote, enabled: true, busy: false) {
          withAnimation(Motion.snappy) { model.setInstallTarget(.mac) }
        }
        DeliveryCard(symbol: "iphone.radiowaves.left.and.right", tint: Color(nsColor: .systemPurple), title: T.installOther, note: T.installOtherNote, enabled: true, busy: false) {
          withAnimation(Motion.snappy) { model.setInstallTarget(.iphone) }
        }
      }
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// The iPhone path: AirDrop or a code, then one answer on the iPhone.
  @ViewBuilder
  func phone(_ build: ShortcutBuild) -> some View {
    let T = model.tr
    let delivery = PhoneDelivery.of(build, model.snapshot.tokens)
    VStack(spacing: Theme.gap) {
      if delivery == .send {
        send(build)
      } else if delivery == .gone {
        // The file is deleted once the Shortcut is in use (it holds the Shortcut's token), or when
        // it was never used in time: nothing is left to send, so the step offers a new copy.
        Button { again(build, delivery) } label: { Text(T.installMakeCopy).frame(minWidth: 88) }
          .primaryAction()
      }
      FirstAnswer(build: build, answered: delivery == .installed)
      steps(build)
    }
  }

  /// A new copy for the same bots. Gone unused: the same replacement again.
  func again(_ build: ShortcutBuild, _ delivery: PhoneDelivery) {
    if let t = model.snapshot.tokens.first(where: { $0.id == build.tokenId }) { model.draft = delivery.again(t) }
    make()
  }

  @ViewBuilder
  func send(_ build: ShortcutBuild) -> some View {
    let T = model.tr
    if !build.signed { UnsignedCopy(build: build) }
    HStack(spacing: 12) {
      DeliveryCard(symbol: "folder", tint: Color(nsColor: .systemBlue), title: T.airdrop, note: T.airdropNote, enabled: true, busy: false) {
        Task { await model.reveal(build.tokenId) }
      }
      // A download link for a file iOS won't import only leads to an error on the phone.
      DeliveryCard(symbol: "qrcode", tint: Color(nsColor: .systemPurple), title: T.scan, note: T.scanNote, enabled: build.signed, busy: linking) {
        guard !linking else { return }
        linking = true
        Task {
          let l = await model.link(build.tokenId)
          linking = false
          // Another Shortcut of the batch picked meanwhile: this code is not for it.
          if let l, model.build?.tokenId == build.tokenId { withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) { link = l } }
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    if let link, let img = QRCode.image(link.url) {
      VStack(spacing: 10) {
        Image(decorative: img, scale: 1)
          .resizable()
          .interpolation(.none)
          .frame(width: 196, height: 196)
          .padding(12)
          .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
          .accessibilityLabel(T.scan)
        Text(T.qrNote).font(.system(size: 12)).foregroundStyle(Theme.muted)
        Text(T.fmt(T.expires, ["time": Date(timeIntervalSince1970: link.expiresAt / 1000).formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(T.locale))]))
          .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.muted)
      }
      .transition(Motion.transition(.scale(scale: 0.92).combined(with: .opacity)))
    }
  }

  /// The steps as an animated iPhone (PhoneGuide), in the iPhone's language (chosen right here; it
  /// is also in Settings); the full sentences are behind (i).
  func steps(_ build: ShortcutBuild) -> some View {
    let T = model.tr
    let P = model.phoneTr
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 4) {
        SectionTitle(text: T.onIphone).fixedSize()
        InfoButton(label: P.phAllSteps, text: build.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n\n"))
        Spacer(minLength: 0)
        Picker(T.phoneLang, selection: Binding(get: { model.snapshot.phoneLang }, set: { l in Task { await model.setLanguages(phoneLang: l, announce: false) } })) {
          ForEach(Lang.allCases, id: \.self) { Text($0.info.name).tag($0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        .help(T.phoneLang)
      }
      PhoneGuide(build: build)
    }
  }
}

/// The This Mac path: add it to Shortcuts here, ask it once here, then use it on the iPhone. Each
/// row is a numbered step that turns into a check; only the current one has a button.
struct MacInstall: View {
  @Environment(AppModel.self) private var model
  let build: ShortcutBuild
  @State private var copying = false

  var body: some View {
    let T = model.tr
    let t = model.snapshot.tokens.first { $0.id == build.tokenId }
    let onDevice = t.map { $0.usedAt != nil || $0.state == .active } ?? false
    let add = InstallState.macAdd(name: build.name, hasFile: t?.hasFile ?? false, signed: build.signed,
                                  opened: model.prefs.addedOnMac.contains(build.tokenId), onDevice: onDevice, library: model.library)
    let added = add == .added
    let here = t?.answeredHereAt != nil
    let there = t?.answeredElsewhereAt != nil
    VStack(spacing: 12) {
      GroupBox {
        StepRow(number: 1, done: added, current: !added, title: added ? T.installAdded : T.installAdd, note: addNote(add), warn: addWarns(add)) {
          addAction(add)
        }
        StepRow(number: 2, done: here, current: added && !here, title: here ? T.installAnsweredHere : T.installTry, note: here ? nil : T.installTryNote) {
          if added && !here {
            Button(T.installTryButton) { model.tryOnMac(build.name) }.buttonStyle(.borderedProminent).controlSize(.regular)
          }
        }
        StepRow(number: 3, done: there, current: here && !there, title: there ? T.installAnsweredThere : T.installOnPhone, note: there ? nil : "\(build.say) · \(T.installOnPhoneNote)") {
          if !there {
            InfoButton(label: T.installOnPhone, text: T.installSyncTip)
            SpeakHelp()
          }
        }
      }
      .animation(.spring(response: 0.4, dampingFraction: 0.8), value: [added, here, there])
      QuietLink(title: T.installSendInstead) { withAnimation(Motion.snappy) { model.setInstallTarget(.iphone) } }
    }
  }

  func addNote(_ s: MacAddState) -> String? {
    let T = model.tr
    switch s {
    case .ready: return T.installAddNote
    case .nameTaken: return T.fmt(T.installTaken, ["name": build.name])
    case .renamed(let copy): return T.fmt(T.installRenamed, ["copy": copy, "name": build.name])
    case .needsSigning: return model.snapshot.appleSigning ? T.installSigning : "\(T.installSigning) \(T.signConsent)"
    case .needsFile: return model.snapshot.appleSigning ? nil : T.signConsent
    case .added: return nil
    }
  }

  func addWarns(_ s: MacAddState) -> Bool {
    switch s {
    case .nameTaken, .renamed, .needsSigning: return true
    default: return false
    }
  }

  @ViewBuilder
  func addAction(_ s: MacAddState) -> some View {
    let T = model.tr
    switch s {
    case .ready:
      Button(T.installAdd) { Task { await model.addOnMac(build.tokenId) } }.buttonStyle(.borderedProminent).controlSize(.regular)
    case .nameTaken:
      Button(T.showInShortcuts) { model.showInShortcuts(build.name) }.controlSize(.regular)
    case .renamed(let copy):
      Button(T.showInShortcuts) { model.showInShortcuts(copy) }.controlSize(.regular)
    case .needsFile, .needsSigning:
      // Without consent the button says that it signs with Apple (the row's note says what that
      // sends); clicking it is the consent.
      Button(model.snapshot.appleSigning ? T.installMakeCopy : T.signAndMake) {
        copying = true
        Task {
          await model.makeCopy(build.tokenId, consent: true)
          copying = false
        }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.regular)
      .disabled(copying)
    case .added:
      EmptyView()
    }
  }
}

/// One numbered step of a row list: a number in a ring, a check once done; the title, one quiet
/// line under it, and the step's control at the trailing edge.
struct StepRow<Accessory: View>: View {
  let number: Int
  let done: Bool
  let current: Bool
  let title: String
  var note: String?
  var warn = false
  @ViewBuilder var accessory: Accessory

  var body: some View {
    Row {
      ZStack {
        Circle().fill(done ? Theme.success : .clear)
        Circle().strokeBorder(done ? .clear : current ? Theme.primary : Theme.border, lineWidth: 1.5)
        if done {
          Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
        } else {
          Text("\(number)").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(current ? Theme.primary : Theme.muted)
        }
      }
      .frame(width: 22, height: 22)
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).foregroundStyle(done || current ? Theme.foreground : Theme.muted).contentTransition(.opacity)
        if let note {
          Text(note).font(.system(size: 12)).foregroundStyle(warn ? Theme.warning : Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      accessory
    }
    .padding(.vertical, 4)
  }
}

/// The finish line of setup: run it once by hand in Shortcuts and ask something. Its first
/// answered request makes it active (DESIGN §7.7), and the row turns to "Answered" with a check.
/// Voice ("Hey Siri, <phrase>") is a bonus under it; what can stop it (HomePod learning time,
/// Personal Requests, the same Siri language, spoken responses) is behind (i).
struct FirstAnswer: View {
  @Environment(AppModel.self) private var model
  let build: ShortcutBuild
  let answered: Bool

  var body: some View {
    let T = model.tr
    let P = model.phoneTr
    VStack(spacing: 8) {
      GroupBox {
        Row {
          ZStack {
            Circle().fill(answered ? Theme.success : Theme.fill)
            if answered {
              Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            } else {
              LiveDot(live: false)
            }
          }
          .frame(width: 22, height: 22)
          InlineInfo {
            Text(answered ? T.answered : T.askOnce)
              .fixedSize(horizontal: false, vertical: true)
              .contentTransition(.opacity)
          } info: {
            // Answered as text only: how to make the iPhone speak.
            SpeakHelp()
          }
          Spacer(minLength: 0)
        }
      }
      .animation(.spring(response: 0.4, dampingFraction: 0.8), value: answered)
      HStack(spacing: 6) {
        SiriOrb(size: 18)
        InlineInfo {
          Text("\(T.phBonus): \(build.say.isEmpty ? build.name : build.say)").font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
        } info: {
          InfoButton(label: T.phBonus, text: P.phSiriTip)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Theme.inset)
    }
  }
}

/// What the iPhone step can offer for the Shortcut made in this visit.
enum PhoneDelivery: Equatable {
  /// Not used yet and its file is here: AirDrop or a QR code.
  case send
  /// Already answered Siri: its file is gone by design; it is on the phone.
  case installed
  /// On the phone (used, so its file is gone) but not answered yet: what it replaces still works
  /// until its first answer (DESIGN §7.7).
  case trying
  /// Not used, but its file is gone (expired or cleaned up): make it again.
  case gone

  static func of(_ build: ShortcutBuild, _ tokens: [TokenView]) -> PhoneDelivery {
    guard let t = tokens.first(where: { $0.id == build.tokenId }) else { return .gone }
    if t.state == .active { return .installed }
    if t.waitingForAnswer { return .trying }
    return t.hasFile ? .send : .gone
  }

  /// The Shortcut step "Make it again" opens: the same bots, language and kind; on a phone, a copy
  /// that replaces nothing (its first answer must not retire the one on the first iPhone); else
  /// what this one replaced.
  func again(_ t: TokenView) -> ShortcutDraft {
    ShortcutDraft(bot: t.bot, replaces: self == .installed || self == .trying ? "" : t.replaces ?? "", entry: t.mode == .entry,
                  siriLang: t.siriLang, conversation: t.mode == .conversation)
  }
}

/// One of the two ways to the phone; the whole card is the button, hover changes its fill only.
struct DeliveryCard: View {
  let symbol: String
  let tint: Color
  let title: String
  let note: String
  let enabled: Bool
  let busy: Bool
  let action: () -> Void
  @State private var hover = false

  var body: some View {
    Button(action: action) {
      VStack(spacing: 8) {
        ZStack {
          Circle().fill(tint.opacity(0.14))
          if busy { ProgressView().controlSize(.small) } else { Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(tint) }
        }
        .frame(width: 44, height: 44)
        Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.foreground)
        Text(note).font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .padding(.vertical, 16)
      .padding(.horizontal, Theme.inset)
      .background(hover && enabled ? Theme.hover : Color.clear, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
      .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.5)
    .onHover { hover = $0 }
  }
}

/// What signing sends to Apple, under a button that signs with Apple (DECISIONS item 24).
struct SignConsentNote: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: "checkmark.seal").foregroundStyle(Theme.muted)
      Text(model.tr.signConsent).fixedSize(horizontal: false, vertical: true)
    }
    .font(.system(size: 12))
    .foregroundStyle(Theme.muted)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Theme.inset)
  }
}

/// An unsigned file on the iPhone path (made by the CLI, or before consent): iOS won't add it,
/// so the step offers a signed copy, with the consent pattern when none is given.
struct UnsignedCopy: View {
  @Environment(AppModel.self) private var model
  let build: ShortcutBuild
  @State private var copying = false

  var body: some View {
    let T = model.tr
    VStack(spacing: 8) {
      Callout(text: T.installSigning) {
        Button(model.snapshot.appleSigning ? T.installMakeCopy : T.signAndMake) {
          copying = true
          Task {
            await model.makeCopy(build.tokenId, consent: true)
            copying = false
          }
        }
        .controlSize(.regular)
        .disabled(copying)
      }
      if !model.snapshot.appleSigning { SignConsentNote() }
    }
  }
}
