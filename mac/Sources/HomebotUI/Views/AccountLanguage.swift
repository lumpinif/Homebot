// Setup step 1 (web/src/app/steps/account.tsx), with the native rules of DESIGN §20.4: a Grok
// Bot CLI login found on this Mac is used without asking, with a quiet "Use an API key instead";
// otherwise the step asks for a Cursor API key, with a note only when a CLI login is there but
// can't be used. No note when there is none: Homebot reads only the CLI's login, so it can't know
// whether the user has Grok Bot (the desktop app signs in elsewhere). Also the suggestion
// after a default language change (Settings; the language step itself is gone, S16 D2).
import AppKit
import HomebotCore
import SwiftUI

/// Where Cursor lists User API Keys. Not yet confirmed against the live dashboard (STATUS).
let cursorKeysURL = URL(string: "https://cursor.com/dashboard?tab=integrations")!

struct AccountStep: View {
  @Environment(AppModel.self) private var model
  let done: () -> Void
  @State private var key = ""
  @State private var phase: StatefulButton.Phase = .idle
  @State private var editing = false
  @State private var confirmRemove = false

  var body: some View {
    let T = model.tr
    let c = model.snapshot.credential
    VStack(spacing: Theme.gap) {
      StepHeader(symbol: "link", tint: Tint.account, title: T.accountTitle)
      Group {
        if c == nil || editing {
          form(c)
            .transition(.opacity.combined(with: .offset(y: 8)))
        } else if let c {
          status(c)
            .transition(.opacity.combined(with: .offset(y: 8)))
        }
      }
      .animation(.easeOut(duration: 0.22), value: editing)
      .animation(.easeOut(duration: 0.22), value: c == nil)
      .animation(.easeOut(duration: 0.22), value: model.canUndoRemoveKey)
    }
    // Read-only, never a message: says whether Grok Bot accepts the key as soon as a bot exists.
    .task { await model.checkKeyIfUnchecked() }
    // A misclick must not lose the key. With a usable Grok Bot login, removing goes back to it.
    .alert(T.removeKeyConfirm, isPresented: $confirmRemove) {
      Button(T.cancel, role: .cancel) {}
      Button(T.removeKey, role: .destructive) { Task { await model.removeKey() } }
    } message: {
      Text(model.snapshot.login == .usable ? T.removeKeyConfirmLogin : T.removeKeyConfirmBody)
    }
  }

  func form(_ c: CredentialView?) -> some View {
    let T = model.tr
    return VStack(spacing: Theme.rowGap) {
      // Right after Remove, where the key row was: the same key back with one click.
      if c == nil && model.canUndoRemoveKey {
        GroupBox {
          Row {
            RowIcon(symbol: "key")
            Text(T.keyRemoved).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer(minLength: 8)
            Button(T.undo) { Task { await model.undoRemoveKey() } }
              .buttonStyle(.borderless)
              .font(.system(size: 12))
          }
        }
        .transition(.opacity)
      }
      if c == nil, let why = loginNote { Callout(text: why, style: .info) }
      GroupBox {
        Field(label: T.apiKey, text: $key, placeholder: T.apiKeyPlaceholder, symbol: "key", secure: true, state: phase == .failed ? .error : .normal, maxLength: 512, onSubmit: save)
      }
      .onChange(of: key) { if phase == .failed { phase = .idle } }
      HStack(spacing: 4) {
        Text(T.apiKeyIn)
        Link(destination: cursorKeysURL) {
          Text(T.cursorDashboard).foregroundStyle(Theme.primary)
        }
        .pointerStyle(.link)
        Text("· \(T.apiKeyStays)")
        Spacer(minLength: 0)
      }
      .font(.system(size: 12))
      .foregroundStyle(Theme.muted)
      .padding(.horizontal, Theme.inset)
      ActionBar {
        Button { NSWorkspace.shared.open(cursorKeysURL) } label: {
          Label(T.apiKeyCreate, systemImage: "arrow.up.right")
        }
        .secondaryAction()
        Spacer()
        if c != nil {
          Button(T.cancel) { editing = false }.buttonStyle(.borderless).controlSize(.large)
        }
        StatefulButton(title: T.save, busyTitle: T.saving, doneTitle: T.saved, failedTitle: T.retry, phase: $phase, disabled: key.trimmingCharacters(in: .whitespaces).isEmpty, action: save)
      }
      .padding(.top, 8)
    }
  }

  var loginNote: String? {
    let T = model.tr
    switch model.snapshot.login {
    case .otherBackend: return T.loginOther
    case .unreadable: return T.loginUnreadable
    case .none, .usable: return nil
    }
  }

  func status(_ c: CredentialView) -> some View {
    let T = model.tr
    return VStack(spacing: Theme.rowGap) {
      GroupBox {
        Row {
          RowIcon(symbol: c.source == .saved ? "key.fill" : "person.crop.circle.badge.checkmark")
          Text(c.source == .saved ? T.keySaved : T.keyDetected).lineLimit(1)
          Spacer(minLength: 8)
          // Shown once Grok Bot answered a check; before a bot exists there is nothing to read.
          HStack(spacing: 6) {
            if c.access != .unchecked {
              StatusDot(text: c.access == .ok ? T.accessOk : T.accessRejected, ok: c.access == .ok)
                .transition(.opacity)
            }
            // The saved key's Remove sits with its status, quiet; the alert still guards it.
            if c.source == .saved {
              if c.access != .unchecked { Text("·").font(.system(size: 12)).foregroundStyle(Theme.muted) }
              DangerLink(title: T.removeKey) { confirmRemove = true }
            }
          }
        }
        .animation(.easeOut, value: c.access)
      }
      if c.source == .bdkLogin { Note(text: T.keyDetectedNote) }
      if c.source == .saved && model.snapshot.login == .usable { Note(text: T.keyOverLogin) }
      ActionBar {
        if c.source == .bdkLogin {
          QuietLink(title: T.useKeyInstead) { editing = true }
        }
        Spacer()
        if c.source == .saved {
          Button(T.replaceKey) { editing = true }.secondaryAction()
        }
        Button(action: done) { Text(T.next).frame(minWidth: 88) }.primaryAction()
      }
      .padding(.top, 8)
    }
  }

  func save() {
    guard !key.trimmingCharacters(in: .whitespaces).isEmpty, phase != .busy else { return }
    phase = .busy
    Task {
      let ok = await model.saveKey(key)
      guard ok else {
        phase = .failed
        return
      }
      key = ""
      phase = .done
      try? await Task.sleep(nanoseconds: 700_000_000)
      editing = false
      phase = .idle
      done()
    }
  }
}

/// Right after the default language changes: an optional suggestion to make the Shortcuts of the
/// old language again in the new one (`Flow.languageSuggestion`). The old ones keep working, so
/// "Not now" simply dismisses it.
struct LanguageSuggestion: View {
  @Environment(AppModel.self) private var model
  /// Called once replacements are made, to deliver them in the iPhone step.
  let made: () -> Void
  @State private var phase: StatefulButton.Phase = .idle

  var body: some View {
    let T = model.tr
    let s = model.snapshot
    let old = Flow.languageSuggestion(s)
    if let first = old.first {
      GroupBox {
        Row {
          Image(systemName: "character.bubble").font(.system(size: 15)).foregroundStyle(Theme.primary).frame(width: 22)
          Text(T.fmt(T.langSuggest, ["lang": Langs.langOfSiri(first.siriLang).info.name, "newLang": Langs.langOfSiri(s.siriLang).info.name]))
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 8)
          Button(T.notNow) { model.dismissLanguageSuggestion() }
            .buttonStyle(.borderless)
            .disabled(phase == .busy)
          StatefulButton(title: !s.appleSigning ? T.signAndMake : old.count == 1 ? T.makeReplacement : T.makeReplacements, busyTitle: T.building, doneTitle: T.built,
                         failedTitle: s.appleSigning ? T.retry : T.signAndMake, phase: $phase, minWidth: 120, disabled: phase == .busy || model.replacing) { make() }
            .controlSize(.regular)
        }
      }
      .transition(.opacity)
      if !s.appleSigning { SignConsentNote().transition(.opacity) }
    }
  }

  func make() {
    phase = .busy
    Task {
      guard !(await model.makeReplacements(consent: true)).isEmpty else {
        phase = .failed
        return
      }
      phase = .done
      try? await Task.sleep(nanoseconds: 650_000_000)
      phase = .idle
      made()
    }
  }
}
