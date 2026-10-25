// Settings' last row: "Reset everything" (AppModel.resetEverything). The confirmation is a native
// critical alert: its checkbox removes the saved key too (off by default), and a small picture
// shows that Shortcuts already on the iPhone and the Mac stop working.
import AppKit
import SwiftUI

struct ResetRow: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let T = model.tr
    GroupBox {
      Row {
        RowIcon(symbol: "arrow.counterclockwise")
        InlineInfo {
          Text(T.resetTitle)
        } info: {
          InfoButton(label: T.resetTitle, text: T.resetNote)
        }
        Spacer(minLength: 12)
        Button("\(T.resetButton)…", role: .destructive) { confirm() }
          .foregroundStyle(Theme.destructive)
          .controlSize(.regular)
          .disabled(model.resetting || model.importing)
      }
    }
  }

  func confirm() {
    let T = model.tr
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = T.confirmReset
    alert.informativeText = T.confirmResetBody
    let reset = alert.addButton(withTitle: T.resetButton)
    reset.hasDestructiveAction = true
    alert.addButton(withTitle: T.cancel)
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = T.resetRemoveKey
    alert.suppressionButton?.state = .off
    let picture = NSHostingView(rootView: StopsWorking())
    picture.frame = NSRect(origin: .zero, size: picture.fittingSize)
    alert.accessoryView = picture
    let done: (NSApplication.ModalResponse) -> Void = { r in
      guard r == .alertFirstButtonReturn else { return }
      let removeKey = alert.suppressionButton?.state == .on
      Task { await model.resetEverything(removeKey: removeKey) }
    }
    if let w = NSApp.keyWindow ?? NSApp.mainWindow {
      alert.beginSheetModal(for: w, completionHandler: done)
    } else {
      done(alert.runModal())
    }
  }
}

/// An iPhone and a Mac, each with a Shortcut that no longer runs.
struct StopsWorking: View {
  var body: some View {
    HStack(spacing: 22) {
      device("iphone")
      device("laptopcomputer")
    }
    .padding(.vertical, 6)
    .frame(width: 220)
    .accessibilityHidden(true)
  }

  func device(_ symbol: String) -> some View {
    Image(systemName: symbol)
      .font(.system(size: 34, weight: .light))
      .foregroundStyle(.secondary)
      .overlay(alignment: .bottomTrailing) {
        Image(systemName: "xmark.circle.fill")
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, Theme.destructive)
          .font(.system(size: 16))
          .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-1.5))
          .offset(x: 7, y: 4)
      }
      .frame(width: 56, height: 44)
  }
}
