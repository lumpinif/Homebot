// The iPhone step's "On your iPhone", as four drawn scenes on an iPhone of our own drawing:
// AirDrop brings the Shortcut and "Add Shortcut" is tapped; its details turn on "Allow Running
// When Locked"; in Shortcuts it is tapped once and its connection allowed; it asks, a question is
// typed, and the answer comes back with a check: that first answer is what finishes setup (the
// step turns to "Answered"); for a conversation Shortcut its caption says the end word. Saying "Hey Siri, <phrase>" is a bonus, behind (i) under the guide.
// Captions and iOS words are in the iPhone's language (`phone`); the phrase, host and prompt are
// the real ones. The full sentences stay one click away, behind the (i) next to the section title.
import SwiftUI

struct PhoneGuide: View {
  @Environment(AppModel.self) private var model
  let build: ShortcutBuild

  var body: some View {
    let P = model.phoneTr
    let T = model.tr
    // A conversation Shortcut keeps listening: its last caption says how to end it.
    let last = build.endWord.map { P.fmt(P.phEndCap, ["word": $0]) } ?? P.phAskCap
    let captions = [P.phAddCap, P.phLockCap, P.phRunCap, last]
    GuidePlayer(captions: captions,
                stageHeight: 340, previous: T.guidePrev, next: T.guideNext,
                stepLabel: { T.fmt(T.guideStep, ["n": "\($0 + 1)", "total": "\(captions.count)"]) },
                chrome: { screen in AnyView(IPhoneFrame { screen }) }) { i, play in
      switch i {
      case 0: AddScene(name: build.name, P: P, play: play)
      case 1: LockedScene(name: build.name, P: P, play: play)
      case 2: AllowScene(name: build.name, host: build.host, P: P, play: play)
      default: AskScene(prompt: build.prompt, P: P, play: play)
      }
    }
  }
}

/// An iPhone of our own drawing: a dark rounded body, the screen, the Dynamic Island.
struct IPhoneFrame<Screen: View>: View {
  static var size: CGSize { CGSize(width: 156, height: 316) }
  @ViewBuilder var screen: Screen

  var body: some View {
    let s = Self.size
    ZStack(alignment: .top) {
      RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color.hex(0x1c1c1e))
      screen
        .frame(width: s.width - 10, height: s.height - 10)
        .background(PhoneColors.screen)
        .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
        .padding(5)
      Capsule().fill(.black).frame(width: 46, height: 13).padding(.top, 11)
    }
    .frame(width: s.width, height: s.height)
    .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
  }
}

/// iOS-like colours that follow the Mac's light or dark appearance.
enum PhoneColors {
  static let screen = Color.dynamic(0xf2f2f7, 0x000000)
  static let cell = Color.dynamic(0xffffff, 0x1c1c1e)
  static let blue = Color.dynamic(0x007aff, 0x0a84ff)
  static let green = Color.dynamic(0x34c759, 0x30d158)
}

/// A line of iOS text in the phone's small scale.
private func phoneText(_ s: String, _ size: CGFloat = 8.5, _ weight: Font.Weight = .regular) -> some View {
  Text(s).font(.system(size: size, weight: weight)).lineLimit(2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
}

/// The Shortcut's tile, as Shortcuts draws one: a coloured rounded square with a glyph.
private struct ShortcutTile: View {
  var size: CGFloat = 40
  var body: some View {
    Image(systemName: "waveform")
      .font(.system(size: size * 0.42, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(LinearGradient(colors: Tint.shortcut, startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
  }
}

/// An iOS switch.
private struct PhoneSwitch: View {
  let on: Bool
  var body: some View {
    Capsule()
      .fill(on ? PhoneColors.green : Color(nsColor: .tertiaryLabelColor))
      .frame(width: 24, height: 14)
      .overlay(alignment: on ? .trailing : .leading) {
        Circle().fill(.white).frame(width: 12, height: 12).padding(1).shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
      }
  }
}

/// AirDrop brings the file; "Add Shortcut" is tapped.
private struct AddScene: View {
  let name: String
  let P: Tr
  let play: Bool
  @State private var sheet = false
  @State private var tap = false
  @State private var added = false

  var body: some View {
    ZStack(alignment: .bottom) {
      VStack(spacing: 8) {
        Capsule().fill(Theme.fill).frame(width: 26, height: 3).padding(.top, 6)
        ShortcutTile(size: 44).padding(.top, 8)
        phoneText(name, 11, .semibold)
        VStack(spacing: 4) { TextBar(width: 92, height: 4); TextBar(width: 70, height: 4) }
        Spacer(minLength: 0)
        ZStack {
          HStack(spacing: 4) {
            if added { Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)) }
            phoneText(P.phAddUI, 9, .semibold)
          }
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity, minHeight: 26)
          .background(added ? PhoneColors.green : PhoneColors.blue, in: Capsule())
          if tap { TapRipple(color: .white, size: 24, delay: 0, play: play) }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 18)
      }
      .frame(height: 220)
      .frame(maxWidth: .infinity)
      .background(PhoneColors.cell, in: UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18, style: .continuous))
      .offset(y: sheet ? 0 : 240)
    }
    // AirDrop's arrival, above the sheet: the file's name with the wireless mark.
    .overlay(alignment: .top) {
      HStack(spacing: 4) {
        Image(systemName: "dot.radiowaves.up.forward").font(.system(size: 8, weight: .semibold)).foregroundStyle(PhoneColors.blue)
        Text(name).font(.system(size: 8, weight: .medium)).lineLimit(1)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(PhoneColors.cell, in: Capsule())
      .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
      .padding(.top, 34)
      .padding(.horizontal, 12)
      .opacity(sheet ? 0 : 1)
      .offset(y: sheet ? -6 : 0)
    }
    .task {
      await beats(play, [
        (1.0, .spring(response: 0.5, dampingFraction: 0.86), { sheet = true }),
        (1.1, .easeOut(duration: 0.15), { tap = true }),
        (0.35, .easeOut(duration: 0.25), { added = true }),
      ])
    }
  }
}

/// Shortcuts: the new tile is tapped once; the connection is allowed.
private struct AllowScene: View {
  let name: String
  let host: String
  let P: Tr
  let play: Bool
  @State private var tap = false
  @State private var alert = false
  @State private var allow = false

  var body: some View {
    ZStack {
      VStack(alignment: .leading, spacing: 8) {
        phoneText(P.phShortcutsUI, 15, .bold).padding(.top, 34)
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
          ZStack {
            VStack(alignment: .leading, spacing: 6) {
              Image(systemName: "waveform").font(.system(size: 11, weight: .semibold))
              Spacer(minLength: 0)
              Text(name).font(.system(size: 8, weight: .semibold)).lineLimit(2)
            }
            .foregroundStyle(.white)
            .padding(7)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(LinearGradient(colors: Tint.shortcut, startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            if tap { TapRipple(color: .white, size: 26, delay: 0, play: play) }
          }
          ForEach([Color.hex(0x5e5ce6), .hex(0xff9f0a), .hex(0x30b0c7)], id: \.self) { c in
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(c.opacity(0.85)).frame(minHeight: 54)
          }
        }
        Spacer()
      }
      .padding(.horizontal, 10)
      .blur(radius: alert ? 1.5 : 0)
      if alert {
        VStack(spacing: 0) {
          phoneText(P.fmt(P.phConnect, ["name": name, "host": host]), 8.5, .semibold)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
          Divider()
          HStack(spacing: 0) {
            phoneText(P.phDenyUI, 8.5).foregroundStyle(PhoneColors.blue).frame(maxWidth: .infinity, minHeight: 24)
            Divider().frame(height: 24)
            phoneText(P.phAllowUI, 8.5, .semibold).foregroundStyle(PhoneColors.blue).frame(maxWidth: .infinity, minHeight: 24)
              .background(allow ? Theme.primary.opacity(0.18) : .clear)
          }
        }
        .frame(width: 124)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
          if allow { TapRipple(color: PhoneColors.blue, size: 22, delay: 0, play: play).offset(x: -20, y: -1) }
        }
        .transition(.scale(scale: 1.1).combined(with: .opacity))
      }
    }
    .task {
      await beats(play, [
        (0.6, .easeOut(duration: 0.15), { tap = true }),
        (0.6, .spring(response: 0.35, dampingFraction: 0.85), { alert = true }),
        (1.1, .easeOut(duration: 0.2), { allow = true }),
      ])
    }
  }
}

/// The Shortcut's details: "Allow Running When Locked" turns on.
private struct LockedScene: View {
  let name: String
  let P: Tr
  let play: Bool
  @State private var on = false

  var body: some View {
    VStack(spacing: 10) {
      HStack(spacing: 6) {
        ShortcutTile(size: 24)
        phoneText(name, 10, .semibold)
        Spacer(minLength: 0)
        Image(systemName: "info.circle.fill").font(.system(size: 12)).foregroundStyle(PhoneColors.blue)
      }
      .padding(.top, 36)
      VStack(spacing: 0) {
        row { TextBar(width: 60, height: 4) }
        Divider().padding(.leading, 8)
        row {
          Text(P.phLockUI).font(.system(size: 8.5)).lineLimit(4).minimumScaleFactor(0.8).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 4)
          PhoneSwitch(on: on)
        }
        .highlighted(radius: 6, play: play)
        Divider().padding(.leading, 8)
        row { TextBar(width: 48, height: 4) }
      }
      .background(PhoneColors.cell, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
      Spacer()
    }
    .padding(.horizontal, 10)
    .task {
      await beats(play, [(1.0, .spring(response: 0.3, dampingFraction: 0.75), { on = true })])
    }
  }

  func row<C: View>(@ViewBuilder _ c: () -> C) -> some View {
    HStack(spacing: 4) { c() }.padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
  }
}

/// The Shortcut runs: its prompt appears, a question is typed, the answer comes back with a check.
private struct AskScene: View {
  let prompt: String
  let P: Tr
  let play: Bool
  @State private var typed = false
  @State private var answered = false

  var body: some View {
    VStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 5) {
          ShortcutTile(size: 16)
          Text(prompt).font(.system(size: 8.5, weight: .semibold)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 4) {
          Text(typed ? P.phAskSample : " ").font(.system(size: 8.5)).lineLimit(1)
          Spacer(minLength: 0)
          Image(systemName: "mic.fill").font(.system(size: 8)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .highlighted(radius: 6, play: play && !typed)
      }
      .padding(9)
      .background(PhoneColors.cell, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .padding(.top, 34)
      if answered {
        HStack(alignment: .top, spacing: 5) {
          Text(P.phAnswerSample).font(.system(size: 8.5)).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
        }
        .padding(9)
        .background(PhoneColors.cell, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .transition(.opacity.combined(with: .offset(y: 6)))
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 30))
          .foregroundStyle(.white, PhoneColors.green)
          .padding(.top, 12)
          .transition(.scale(scale: 0.6).combined(with: .opacity))
      }
      Spacer()
    }
    .padding(.horizontal, 10)
    .task {
      await beats(play, [
        (0.9, .easeOut(duration: 0.2), { typed = true }),
        (1.0, .spring(response: 0.4, dampingFraction: 0.8), { answered = true }),
      ])
    }
  }
}
