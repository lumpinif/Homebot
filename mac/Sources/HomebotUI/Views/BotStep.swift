// Setup step 3 (web/src/app/steps/bot.tsx) plus DESIGN §20.7: add by exact name typed twice
// (a typo makes Grok Bot create an empty bot, which is detected and not added), strict reply
// checking with a confirmed opt-out, rename what Siri calls a bot, and under Advanced: add by
// session id, or explicitly create a new bot after a confirmation.
import HomebotCore
import SwiftUI

struct BotStep: View {
  @Environment(AppModel.self) private var model
  let done: () -> Void

  @State private var name = ""
  @State private var again = ""
  @State private var strict = true
  @State private var phase: StatefulButton.Phase = .idle
  @State private var sid = ""
  @State private var sidName = ""
  @State private var sidStrict = true
  @State private var sidPhase: StatefulButton.Phase = .idle
  @State private var newName = ""
  @State private var newPhase: StatefulButton.Phase = .idle
  @State private var addOpen = false
  @State private var advancedOpen = false
  @State private var confirmNonStrict: ((Bool) -> Void)?
  @State private var removing: BotView?
  @State private var renaming: BotView?
  @State private var renameText = ""
  @State private var confirmCreate = false

  var body: some View {
    let T = model.tr
    let bots = model.snapshot.bots
    VStack(spacing: Theme.gap) {
      StepHeader(symbol: "sparkle.magnifyingglass", tint: Tint.bot, title: T.botTitle)
      if !bots.isEmpty {
        GroupBox {
          ForEach(bots) { b in botRow(b) }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: bots)
      }
      VStack(spacing: 8) {
        if bots.isEmpty {
          addForm.padding(.bottom, 12)
        } else {
          Disclosure(title: T.addAnother, open: $addOpen) { addForm.padding(.bottom, 12) }
        }
        Disclosure(title: T.advanced, open: $advancedOpen) { advanced.padding(.bottom, 4) }
      }
      if !bots.isEmpty {
        ActionBar {
          Button(action: done) { Text(T.next).frame(minWidth: 88) }.primaryAction()
        }
      }
    }
    .alert(T.confirmNonStrict, isPresented: Binding(get: { confirmNonStrict != nil }, set: { if !$0 { confirmNonStrict = nil } })) {
      Button(T.cancel, role: .cancel) { confirmNonStrict = nil }
      Button(T.turnOff, role: .destructive) {
        confirmNonStrict?(false)
        confirmNonStrict = nil
      }
    } message: {
      Text(T.confirmNonStrictBody)
    }
    .alert(model.tr.fmt(T.confirmRemoveBot, ["name": removing?.name ?? ""]), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
      Button(T.cancel, role: .cancel) { removing = nil }
      Button(T.removeBot, role: .destructive) {
        if let b = removing { Task { await model.removeBot(b.key) } }
        removing = nil
      }
    } message: {
      Text(T.confirmRemoveBotBody)
    }
    .alert(model.tr.fmt(T.confirmCreate, ["name": newName.trimmingCharacters(in: .whitespaces)]), isPresented: $confirmCreate) {
      Button(T.cancel, role: .cancel) {}
      Button(T.create) { create() }
    } message: {
      Text(T.confirmCreateBody)
    }
    .sheet(item: $renaming) { b in renameSheet(b) }
  }

  func botRow(_ b: BotView) -> some View {
    let T = model.tr
    return Row {
      GrokBotAvatar(size: 30)
      VStack(alignment: .leading, spacing: 2) {
        Text(b.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
        Text(b.sessionId).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1)
      }
      Spacer(minLength: 8)
      if !b.strictEcho { Badge(text: T.strictOff, style: .warning, dot: true) }
      IconButton(symbol: "pencil", help: T.rename) {
        renameText = b.name
        renaming = b
      }
      IconButton(symbol: "trash", help: T.removeBot, destructiveHover: true) { removing = b }
    }
    .transition(Motion.transition(.opacity.combined(with: .move(edge: .top))))
  }

  /// Strict checking off needs an explicit "yes" after the privacy warning (DESIGN §4.2).
  func strictRow(_ on: Binding<Bool>) -> some View {
    let T = model.tr
    return Row {
      RowIcon(symbol: "checkmark.shield.fill", color: Theme.success)
      Text(T.strict).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      Badge(text: T.recommended, style: .success)
      Toggle(T.strict, isOn: Binding(get: { on.wrappedValue }, set: { v in
        if v { on.wrappedValue = true } else { confirmNonStrict = { on.wrappedValue = $0 } }
      }))
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.small)
      // Green, as on the setup page: the safe, recommended setting.
      .tint(Theme.success)
    }
  }

  var addForm: some View {
    let T = model.tr
    let mismatch = !again.isEmpty && again.trimmingCharacters(in: .whitespaces) != name.trimmingCharacters(in: .whitespaces)
    let match = !again.trimmingCharacters(in: .whitespaces).isEmpty && !mismatch
    let ready = !name.trimmingCharacters(in: .whitespaces).isEmpty && match
    return VStack(spacing: 8) {
      GroupBox {
        Field(label: T.botName, text: $name, placeholder: T.botNamePlaceholder, state: phase == .failed ? .error : .normal, maxLength: Bot.maxNameLength)
        Field(label: T.botConfirm, text: $again, placeholder: T.botConfirmPlaceholder, state: mismatch ? .error : match ? .success : .normal, maxLength: Bot.maxNameLength) {
          if ready { addByName() }
        }
        strictRow($strict)
      }
      .onChange(of: name) { if phase == .failed { phase = .idle } }
      Note(text: T.botNameNote)
      ActionBar {
        if phase == .busy { Text(T.adding).font(.system(size: 12)).foregroundStyle(Theme.muted).transition(.opacity) }
        StatefulButton(title: T.add, busyTitle: T.add, doneTitle: T.saved, failedTitle: T.retry, phase: $phase, prominent: model.snapshot.bots.isEmpty, disabled: !ready, action: addByName)
      }
      .padding(.top, 4)
    }
  }

  var advanced: some View {
    let T = model.tr
    let sidOK = !sid.isEmpty && sid.allSatisfy(\.isNumber) && !sidName.trimmingCharacters(in: .whitespaces).isEmpty
    return VStack(spacing: Theme.gap) {
      VStack(spacing: 8) {
        SectionTitle(text: T.bySession)
        GroupBox {
          Field(label: T.sessionId, text: $sid, mono: true, maxLength: 40)
          Field(label: T.spokenName, text: $sidName, maxLength: Bot.maxNameLength)
          strictRow($sidStrict)
        }
        ActionBar {
          StatefulButton(title: T.add, doneTitle: T.saved, failedTitle: T.retry, phase: $sidPhase, prominent: false, disabled: !sidOK) {
            sidPhase = .busy
            Task {
              let ok = await model.addBySession(sid, name: sidName, strict: sidStrict)
              finish(ok, $sidPhase) {
                sid = ""
                sidName = ""
                sidStrict = true
              }
            }
          }
        }
      }
      VStack(spacing: 8) {
        SectionTitle(text: T.createBot)
        GroupBox {
          Field(label: "", text: $newName, placeholder: T.botName, maxLength: Bot.maxNameLength)
        }
        Note(text: T.createBotNote)
        ActionBar {
          StatefulButton(title: T.create, doneTitle: T.saved, failedTitle: T.retry, phase: $newPhase, prominent: false, disabled: newName.trimmingCharacters(in: .whitespaces).isEmpty) {
            confirmCreate = true
          }
        }
      }
    }
  }

  func renameSheet(_ b: BotView) -> some View {
    let T = model.tr
    return VStack(alignment: .leading, spacing: 12) {
      Text(T.renameTitle).font(.system(size: 15, weight: .semibold))
      GroupBox {
        Field(label: "", text: $renameText, maxLength: Bot.maxNameLength) { rename(b) }
      }
      Note(text: T.renameNote)
      ActionBar {
        Button(T.cancel) { renaming = nil }.keyboardShortcut(.cancelAction).secondaryAction()
        Button(T.save) { rename(b) }
          .keyboardShortcut(.defaultAction)
          .primaryAction()
          .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(22)
    .frame(width: 380)
  }

  func rename(_ b: BotView) {
    let n = renameText
    renaming = nil
    Task { _ = await model.renameBot(b.key, to: n) }
  }

  func addByName() {
    phase = .busy
    Task {
      let ok = await model.addByName(name, confirm: again, strict: strict)
      finish(ok, $phase) {
        name = ""
        again = ""
        strict = true
        addOpen = false
      }
    }
  }

  func create() {
    newPhase = .busy
    Task {
      let ok = await model.createBot(newName)
      finish(ok, $newPhase) { newName = "" }
    }
  }

  func finish(_ ok: Bool, _ p: Binding<StatefulButton.Phase>, clear: () -> Void) {
    guard ok else {
      p.wrappedValue = .failed
      return
    }
    clear()
    p.wrappedValue = .done
    Task {
      try? await Task.sleep(nanoseconds: 1_400_000_000)
      if p.wrappedValue == .done { p.wrappedValue = .idle }
    }
  }
}
