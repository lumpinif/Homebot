// "Why didn't Siri speak?": a small (?) that opens the iPhone setting that makes Siri read answers
// aloud, drawn as an iOS settings list (Settings › Siri › Responses, "Prefer Spoken" checked),
// with one line on when the iPhone only shows text. iOS words are in the iPhone's language. The
// Mac can't open iPhone settings, so it only shows the path.
import SwiftUI

struct SpeakHelp: View {
  @Environment(AppModel.self) private var model
  @State private var open = false
  @State private var hover = false

  var body: some View {
    let T = model.tr
    Button { open.toggle() } label: {
      Image(systemName: "questionmark.circle")
        .font(.system(size: 13))
        .foregroundStyle(hover || open ? Theme.foreground : Theme.muted)
        .frame(width: Theme.infoButton, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .help(T.speakWhy)
    .accessibilityLabel(T.speakWhy)
    .popover(isPresented: $open, arrowEdge: .bottom) {
      SpeakHelpCard(T: T, P: model.phoneTr)
    }
  }
}

/// The popover: the title, the drawn settings list, the one line.
struct SpeakHelpCard: View {
  let T: Tr
  let P: Tr

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(T.speakWhy).font(.system(size: 13, weight: .semibold))
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 4) {
          Image(systemName: "gearshape.fill").foregroundStyle(.gray)
          Text([P.phSettingsUI, "Siri", P.phResponsesUI].joined(separator: " › "))
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.muted)
        VStack(spacing: 0) {
          option(P.phAutoUI, on: false)
          Divider().padding(.leading, 12)
          option(P.phSpokenUI, on: true)
        }
        .background(PhoneColors.cell, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
      }
      .padding(10)
      .background(PhoneColors.screen, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      Text(T.speakWhyNote)
        .font(.system(size: 12))
        .foregroundStyle(Theme.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(width: 280, alignment: .leading)
    .padding(14)
  }

  func option(_ label: String, on: Bool) -> some View {
    HStack {
      Text(label).font(.system(size: 12))
      Spacer(minLength: 8)
      Image(systemName: "checkmark")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(PhoneColors.blue)
        .opacity(on ? 1 : 0)
    }
    .padding(.horizontal, 12)
    .frame(height: 32)
    .background(on ? PhoneColors.blue.opacity(0.1) : .clear)
  }
}
