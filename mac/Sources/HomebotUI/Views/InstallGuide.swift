// Help › Install or update, as five drawn scenes (no Apple screenshots): the zip in Downloads
// opens to Homebot; Homebot is dragged onto Applications; macOS says "Homebot.app" Not Opened
// and Done is the button to click; System Settings › Privacy & Security with Open Anyway; then
// Homebot in the menu bar. Each scene plays its own small motion once when it appears (a pointer
// moves and clicks), and shows its end frame when `play` is false (Reduce Motion).
import SwiftUI

struct InstallGuide: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let T = model.tr
    GuidePlayer(captions: [T.guideZip, T.guideDrag, T.guideDone, T.guideAnyway, T.guideRuns],
                stageHeight: 250, previous: T.guidePrev, next: T.guideNext,
                stepLabel: { T.fmt(T.guideStep, ["n": "\($0 + 1)", "total": "5"]) }) { i, play in
      switch i {
      case 0: ZipScene(play: play)
      case 1: DragScene(play: play)
      case 2: NotOpenedScene(play: play)
      case 3: OpenAnywayScene(play: play)
      default: MenuBarScene(play: play)
      }
    }
  }
}

// MARK: pieces

/// A small Mac window: title bar with the three buttons, then its content.
struct MiniWindow<Content: View>: View {
  var title: String?
  let width: CGFloat
  let height: CGFloat
  @ViewBuilder var content: Content

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 5) {
        ForEach([Color.hex(0xff5f57), .hex(0xfebc2e), .hex(0x28c840)], id: \.self) { c in
          Circle().fill(c).frame(width: 7, height: 7)
        }
        Spacer()
      }
      .overlay {
        if let title { Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted).lineLimit(1) }
      }
      .padding(.horizontal, 9)
      .frame(height: 24)
      content.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(width: width, height: height)
    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
    .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
  }
}

/// The Mac pointer: a black arrow with a white edge.
struct MacPointer: View {
  var body: some View {
    ZStack {
      Image(systemName: "cursorarrow").font(.system(size: 19, weight: .black)).foregroundStyle(.white)
      Image(systemName: "cursorarrow").font(.system(size: 16, weight: .regular)).foregroundStyle(.black)
    }
    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
    .allowsHitTesting(false)
  }
}

/// A grey bar standing for a line of text the user doesn't need to read.
struct TextBar: View {
  var width: CGFloat
  var height: CGFloat = 5
  var body: some View { Capsule().fill(Theme.fill).frame(width: width, height: height) }
}

/// A file or app in Finder: its icon and its name under it.
struct FinderItem<Icon: View>: View {
  let name: String
  var selected = false
  @ViewBuilder var icon: Icon
  var body: some View {
    VStack(spacing: 4) {
      icon.frame(width: 46, height: 46)
      Text(name)
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(selected ? .white : Theme.foreground)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(selected ? Theme.primary : .clear, in: Capsule())
        .lineLimit(1)
    }
  }
}

/// Homebot's icon in the user's chosen style.
struct HomebotIcon: View {
  @Environment(AppModel.self) private var model
  @Environment(\.colorScheme) private var scheme
  var size: CGFloat = 42
  var body: some View { MarkDrawing(size: size, style: model.prefs.icon.resolved(dark: scheme == .dark)) }
}

/// The accent ring that marks the control to click; it breathes while `play`.
struct Highlight: ViewModifier {
  var radius: CGFloat
  var play: Bool
  @State private var on = false
  func body(content: Content) -> some View {
    content
      .overlay(
        RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
          .strokeBorder(Theme.primary, lineWidth: 2)
          .padding(-3.5)
          .opacity(on ? 1 : 0.45))
      .onAppear {
        guard play else { on = true; return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
      }
  }
}

extension View {
  func highlighted(radius: CGFloat, play: Bool) -> some View { modifier(Highlight(radius: radius, play: play)) }
}

/// Runs a scene's beats: each beat after its delay (seconds from the previous one), animated.
/// Without `play`, every beat applies at once with no animation (the end frame).
@MainActor
func beats(_ play: Bool, _ steps: [(Double, Animation, () -> Void)]) async {
  guard play else {
    for s in steps { s.2() }
    return
  }
  for (delay, animation, change) in steps {
    try? await Task.sleep(for: .seconds(delay))
    if Task.isCancelled { return }
    withAnimation(animation) { change() }
  }
}

// MARK: scenes

/// Downloads: a double-click on Homebot.zip, and Homebot appears next to it.
struct ZipScene: View {
  @Environment(AppModel.self) private var model
  let play: Bool
  @State private var pointer = CGPoint(x: 150, y: 70)
  @State private var opened = false
  @State private var click = false

  var body: some View {
    MiniWindow(title: model.tr.macDownloads, width: 340, height: 180) {
      ZStack(alignment: .topLeading) {
        HStack(spacing: 46) {
          FinderItem(name: "Homebot.zip", selected: click) {
            Image(systemName: "doc.zipper").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.muted)
          }
          FinderItem(name: "Homebot") { HomebotIcon() }
            .scaleEffect(opened ? 1 : 0.5)
            .opacity(opened ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        if click { TapRipple(color: Theme.primary, size: 30, delay: 0, count: 2, play: play).position(x: 110, y: 66) }
        // The arrow's tip lands about 8 pt below `pointer`.
        MacPointer().position(pointer).offset(x: 5, y: 8)
      }
    }
    .task {
      await beats(play, [
        (0.4, .easeInOut(duration: 0.8), { pointer = CGPoint(x: 112, y: 64) }),
        (0.9, .easeOut(duration: 0.15), { click = true }),
        (0.9, .spring(response: 0.45, dampingFraction: 0.75), { opened = true }),
      ])
    }
  }
}

/// Finder: Homebot is dragged onto Applications in the sidebar.
struct DragScene: View {
  @Environment(AppModel.self) private var model
  let play: Bool
  @State private var drag = CGSize.zero
  @State private var lifted = false
  @State private var dropped = false

  var body: some View {
    let T = model.tr
    MiniWindow(title: T.macDownloads, width: 380, height: 190) {
      HStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 6) {
          sidebarRow("arrow.down.circle", T.macDownloads, selected: !dropped && !lifted)
          sidebarRow("square.grid.2x2", T.macApplications, selected: false, target: lifted)
          HStack(spacing: 6) { Image(systemName: "menubar.dock.rectangle").font(.system(size: 10)).foregroundStyle(Theme.primary); TextBar(width: 40) }.padding(.leading, 6)
          HStack(spacing: 6) { Image(systemName: "doc").font(.system(size: 10)).foregroundStyle(Theme.primary); TextBar(width: 52) }.padding(.leading, 6)
          Spacer()
        }
        .padding(8)
        .frame(width: 128, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(Theme.card)
        ZStack {
          FinderItem(name: "Homebot") { HomebotIcon() }.opacity(dropped ? 0.35 : 1)
          // The copy under the pointer while dragging.
          ZStack(alignment: .topLeading) {
            HomebotIcon().opacity(0.75).scaleEffect(dropped ? 0.3 : 0.85)
            MacPointer().offset(x: 22, y: 22)
          }
          .frame(width: 46, height: 46)
          .offset(drag)
          .offset(y: -8)
          .opacity(lifted ? (dropped ? 0 : 1) : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task {
      await beats(play, [
        (0.5, .easeOut(duration: 0.25), { lifted = true }),
        (0.25, .easeInOut(duration: 1.1), { drag = CGSize(width: -158, height: -36) }),
        (1.3, .easeIn(duration: 0.3), { dropped = true }),
      ])
    }
  }

  func sidebarRow(_ symbol: String, _ title: String, selected: Bool, target: Bool = false) -> some View {
    HStack(spacing: 6) {
      Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(target ? .white : Theme.primary)
      Text(title).font(.system(size: 10)).lineLimit(1).foregroundStyle(target ? .white : Theme.foreground)
    }
    .padding(.horizontal, 6)
    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
    .background(target ? Theme.primary : selected ? Theme.active : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
  }
}

/// macOS: "Homebot.app" Not Opened. Done (not Move to Trash) is the button.
struct NotOpenedScene: View {
  @Environment(AppModel.self) private var model
  let play: Bool
  @State private var pointer = CGPoint(x: 210, y: 210)
  @State private var click = false

  var body: some View {
    let T = model.tr
    ZStack(alignment: .topLeading) {
      VStack(spacing: 8) {
        ZStack(alignment: .bottomTrailing) {
          HomebotIcon(size: 40)
          Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).font(.system(size: 15)).offset(x: 5, y: 3)
        }
        Text(T.macNotOpened).font(.system(size: 11, weight: .bold)).multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        VStack(spacing: 4) { TextBar(width: 150); TextBar(width: 120) }
        VStack(spacing: 6) {
          Text(T.done)
            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 22)
            .background(Theme.primary, in: Capsule())
            .highlighted(radius: 11, play: play)
          Text(T.macTrash)
            .font(.system(size: 10.5)).foregroundStyle(Theme.foreground)
            .frame(maxWidth: .infinity, minHeight: 22)
            .background(Theme.fill, in: Capsule())
        }
        .padding(.top, 4)
      }
      .padding(16)
      .frame(width: 210)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
      .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
      .frame(width: 300, height: 240)
      if click { TapRipple(color: Theme.primary, size: 26, delay: 0, play: play).position(x: 150, y: 154) }
      MacPointer().position(pointer).offset(x: 5, y: 8)
    }
    .frame(width: 300, height: 240)
    .task {
      await beats(play, [
        (0.5, .easeInOut(duration: 0.8), { pointer = CGPoint(x: 150, y: 146) }),
        (0.9, .easeOut(duration: 0.15), { click = true }),
      ])
    }
  }
}

/// System Settings › Privacy & Security: Open Anyway, next to the line about Homebot.
struct OpenAnywayScene: View {
  @Environment(AppModel.self) private var model
  let play: Bool
  @State private var pointer = CGPoint(x: 300, y: 40)
  @State private var click = false

  var body: some View {
    let T = model.tr
    MiniWindow(width: 420, height: 206) {
      ZStack(alignment: .topLeading) {
        HStack(spacing: 0) {
          VStack(alignment: .leading, spacing: 5) {
            ForEach([Color.hex(0x8e8e93), .hex(0x0a84ff), .hex(0x34c759)], id: \.self) { c in
              HStack(spacing: 6) { RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 13, height: 13); TextBar(width: 52) }.padding(.horizontal, 6).frame(height: 18)
            }
            HStack(spacing: 6) {
              Image(systemName: "hand.raised.fill").font(.system(size: 7.5)).foregroundStyle(.white)
                .frame(width: 13, height: 13).background(Color.hex(0x0a84ff), in: RoundedRectangle(cornerRadius: 3))
              Text(T.macPrivacy).font(.system(size: 9.5)).foregroundStyle(.white).lineLimit(1)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
            .background(Theme.primary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            ForEach([Color.hex(0xff9f0a), .hex(0x8e8e93)], id: \.self) { c in
              HStack(spacing: 6) { RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 13, height: 13); TextBar(width: 46) }.padding(.horizontal, 6).frame(height: 18)
            }
            Spacer()
          }
          .padding(8)
          .frame(width: 140, alignment: .leading)
          .frame(maxHeight: .infinity)
          .background(Theme.card)
          VStack(alignment: .leading, spacing: 9) {
            Text(T.macPrivacy).font(.system(size: 12, weight: .bold)).lineLimit(1)
            VStack(alignment: .leading, spacing: 5) { TextBar(width: 170); TextBar(width: 130) }
            VStack(alignment: .leading, spacing: 8) {
              HStack(spacing: 6) {
                HomebotIcon(size: 16)
                VStack(alignment: .leading, spacing: 4) { TextBar(width: 92); TextBar(width: 64) }
                Spacer(minLength: 4)
                Text(T.macOpenAnyway)
                  .font(.system(size: 9.5, weight: .medium))
                  .lineLimit(1)
                  .padding(.horizontal, 8)
                  .frame(minHeight: 19)
                  .background(Color(nsColor: .controlColor), in: Capsule())
                  .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
                  .highlighted(radius: 9.5, play: play)
              }
            }
            .padding(9)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 14)
          .padding(.top, 2)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        if click { TapRipple(color: Theme.primary, size: 24, delay: 0, play: play).position(x: 372, y: 82) }
        MacPointer().position(pointer).offset(x: 5, y: 8)
      }
    }
    .task {
      await beats(play, [
        (0.5, .easeInOut(duration: 0.9), { pointer = CGPoint(x: 368, y: 74) }),
        (1.0, .easeOut(duration: 0.15), { click = true }),
      ])
    }
  }
}

/// The menu bar: Homebot's icon arrives, and its menu shows it running.
struct MenuBarScene: View {
  @Environment(AppModel.self) private var model
  let play: Bool
  @State private var arrived = false
  @State private var menu = false

  var body: some View {
    let T = model.tr
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        TextBar(width: 26, height: 6)
        TextBar(width: 34, height: 6)
        TextBar(width: 28, height: 6)
        Spacer()
        Image(nsImage: MenuBarIcon.image())
          .renderingMode(.template)
          .foregroundStyle(Theme.foreground)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(menu ? Theme.active : .clear, in: RoundedRectangle(cornerRadius: 4))
          .scaleEffect(arrived ? 1 : 0.2)
          .opacity(arrived ? 1 : 0)
        Image(systemName: "wifi").font(.system(size: 11))
        Image(systemName: "battery.75percent").font(.system(size: 13))
        Text("9:41").font(.system(size: 11, weight: .medium)).monospacedDigit()
      }
      .foregroundStyle(Theme.foreground)
      .padding(.horizontal, 14)
      .frame(height: 26)
      .background(.bar)
      HStack {
        Spacer()
        VStack(alignment: .leading, spacing: 7) {
          HStack(spacing: 6) {
            Circle().fill(Theme.success).frame(width: 7, height: 7)
            Text(T.menuRunning).font(.system(size: 11, weight: .medium)).lineLimit(1)
          }
          Divider()
          TextBar(width: 90)
          TextBar(width: 70)
        }
        .padding(10)
        .frame(width: 190, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .opacity(menu ? 1 : 0)
        .offset(y: menu ? 0 : -6)
        .padding(.trailing, 96)
      }
      .padding(.top, 4)
      Spacer()
    }
    .task {
      await beats(play, [
        (0.5, .spring(response: 0.45, dampingFraction: 0.6), { arrived = true }),
        (0.9, .easeOut(duration: 0.25), { menu = true }),
      ])
    }
  }
}
