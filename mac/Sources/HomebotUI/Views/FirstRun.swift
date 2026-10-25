// First run (DESIGN §20.9 S5): the notices above every page (run from Applications, import the
// earlier version's setup), the login item notes, and the Help page with the install steps of
// docs/INSTALL.md as a drawn guide. Nothing here acts without a click: the import, the login
// item and the keep-awake switch each wait for the user.
import AppKit
import HomebotCore
import SwiftUI

struct FirstRunNotices: View {
  @Environment(AppModel.self) private var model
  let go: (Page) -> Void

  var body: some View {
    let T = model.tr
    VStack(spacing: 12) {
      if model.placement != .applications {
        Callout(text: model.placement == .translocated ? T.moveTranslocated : T.moveOutside, style: model.placement == .translocated ? .danger : .warning, title: T.moveTitle)
      }
      if model.offersImport { ImportCard() }
    }
  }
}

/// The earlier Homebot's setup was found: what it holds, what the import does, and the explicit
/// button (§20.4, §20.11 B8).
struct ImportCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let T = model.tr
    if let p = model.legacy {
      let live = p.tokens.filter { $0.state != "retired" }
      let botNames = Dictionary(uniqueKeysWithValues: p.bots.map { ($0.key, $0.name) })
      let sessionless = live.filter { $0.sessionless && botNames[$0.bot] != nil }
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 10) {
          Image(systemName: "tray.and.arrow.down").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.primary).frame(width: 22)
          InlineInfo {
            Text(T.importTitle).font(.system(size: 15, weight: .semibold))
          } info: {
            InfoButton(label: T.importTitle, text: T.importWhy)
          }
        }
        VStack(alignment: .leading, spacing: 6) {
          Text(T.fmt(T.importFound, ["folder": model.legacyFolderName, "bots": "\(p.bots.count)", "shortcuts": "\(live.count)"]))
          if p.hasKey { Text(T.importKey) }
        }
        .font(.system(size: 13))
        .fixedSize(horizontal: false, vertical: true)
        if !sessionless.isEmpty {
          GroupBox {
            ForEach(sessionless, id: \.id) { t in
              let on = model.importKeep.contains(t.id)
              Row {
                VStack(alignment: .leading, spacing: 2) {
                  Text(T.fmt(T.importKeep, ["label": t.label, "bot": botNames[t.bot] ?? t.bot])).font(.system(size: 13)).lineLimit(1)
                  Text(T.importKeepNote).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle(t.label, isOn: Binding(get: { on }, set: { v in if v { model.importKeep.insert(t.id) } else { model.importKeep.remove(t.id) } }))
                  .labelsHidden().toggleStyle(.switch)
              }
            }
          }
        }
        Note(text: T.importStop)
        ActionBar {
          Button(T.importLater) { model.dismissImport() }
            .secondaryAction()
            .disabled(model.importing)
          Button(model.importing ? T.importing : T.importButton) { Task { await model.importLegacy() } }
            .primaryAction()
            .disabled(model.importing)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
  }
}

/// What the login item switch could not do, and the approval it may still need.
struct LoginItemNotes: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let T = model.tr
    if let e = model.loginItemError { Callout(text: e == .translocated ? T.loginTranslocated : T.loginFailed, style: .danger) }
    if model.loginItem == .needsApproval {
      Callout(text: T.loginNeedsApproval) {
        Button(T.openLoginItems) { model.openLoginItemsSettings() }.secondaryAction().controlSize(.regular)
      }
    }
  }
}

/// Help: the install and update steps as an animated, drawn guide (InstallGuide), then this Mac's
/// facts as short rows with their details behind (i), and where the command-line tool is for an AI
/// agent.
struct HelpView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let T = model.tr
    VStack(alignment: .leading, spacing: Theme.gap) {
      VStack(alignment: .leading, spacing: 8) {
        SectionTitle(text: T.helpInstall) {
          // The same steps in full sentences, also for VoiceOver (the drawings are decoration).
          InfoButton(label: T.phAllSteps, text: [T.help1, T.help2, T.help3, T.help4, T.help5].enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n\n"))
        }
        InstallGuide()
        HStack(spacing: 6) {
          Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11))
          Text(T.guideUpdate).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, Theme.inset)
      }
      VStack(alignment: .leading, spacing: 8) {
        SectionTitle(text: T.sectionMac)
        GroupBox {
          fact("lock.fill", .systemBlue, T.privacyShort, T.activityNote)
          fact("house.fill", .systemOrange, T.helpHomeNet, T.plainHttp)
          fact("moon.zzz.fill", .systemIndigo, T.helpAwake, T.sleepNote)
          fact("terminal.fill", .systemGray, T.helpAgentShort, T.fmt(T.helpAgent, ["path": model.cliPath]))
        }
      }
      StayInTouch()
    }
  }

  /// One fact: a tinted symbol, a few words, the full sentence behind (i).
  func fact(_ symbol: String, _ tint: NSColor, _ title: String, _ detail: String) -> some View {
    Row {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 22, height: 22)
        .background(Color(nsColor: tint).gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      InlineInfo {
        Text(title)
      } info: {
        InfoButton(label: title, text: detail)
      }
      Spacer(minLength: 8)
    }
  }
}

/// Help's last section: an email sign-up for product updates, the one list. homebot.fun sends a
/// confirmation link first and answers the same for any address (cloud/src/email.ts).
struct StayInTouch: View {
  @Environment(AppModel.self) private var model
  @State private var email = ""
  @State private var sending = false
  @State private var result: String?

  var valid: Bool {
    let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
    return e.count <= 254 && e.wholeMatch(of: /[^\s@]+@[^\s@]+\.[^\s@]+/) != nil
  }

  var body: some View {
    let T = model.tr
    VStack(alignment: .leading, spacing: 8) {
      SectionTitle(text: T.stayTitle)
      GroupBox {
        Row {
          RowIcon(symbol: "envelope")
          TextField(T.emailPlaceholder, text: $email)
            .textFieldStyle(.roundedBorder)
            .textContentType(.emailAddress)
            .onSubmit { send() }
          Button(T.emailSubscribe) { send() }
            .secondaryAction().controlSize(.regular)
            .disabled(sending || !valid)
        }
      }
      Note(text: result ?? T.emailNote)
    }
    .onChange(of: email) { result = nil }
  }

  func send() {
    guard valid, !sending else { return }
    sending = true
    Task {
      let ok = await model.subscribe(email: email)
      sending = false
      result = ok ? model.tr.emailSent : model.tr.emailFailed
    }
  }
}
