// The menu bar item (DESIGN §20.2, §20.6 A7): running state, the last request's outcome and time
// (never its text), open the window, quit. Its icon is the mark's roofline and eyes as a template
// image, so it follows the menu bar's colours.
import AppKit
import SwiftUI

public struct MenuBarContent: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openWindow) private var openWindow

  public init() {}

  public var body: some View {
    let T = model.tr
    let running = model.status?.running == true
    Text(running ? T.menuRunning : T.menuStopped)
    if let at = model.status?.lastAt, let o = model.status?.lastOutcome {
      Text(T.fmt(T.menuLast, ["outcome": T.outcomeLabel(o), "time": Date(timeIntervalSince1970: at / 1000).formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(T.locale))]))
    } else {
      Text(T.menuLastNone)
    }
    Divider()
    Button(T.menuOpen) {
      openWindow(id: "main")
      model.showInDock()
      NSApp.activate()
    }
    .keyboardShortcut("o")
    Divider()
    Button(T.menuQuit) { NSApp.terminate(nil) }.keyboardShortcut("q")
  }
}

/// The app menu's Settings… item (Cmd-,), as in first-party apps: it brings the window forward
/// on the Settings page.
public struct SettingsCommand: View {
  let model: AppModel
  @Environment(\.openWindow) private var openWindow

  public init(model: AppModel) { self.model = model }

  public var body: some View {
    Button("\(model.tr.navSettings)…") {
      openWindow(id: "main")
      model.showInDock()
      NSApp.activate()
      withAnimation(Motion.reduced ? .easeOut(duration: 0.15) : Motion.snappy) { model.go(.settings) }
    }
    .keyboardShortcut(",")
  }
}

public enum MenuBarIcon {
  /// The roofline over two eyes, black on clear, marked as a template image.
  @MainActor
  public static func image(dimmed: Bool = false) -> NSImage {
    let view = Canvas { ctx, size in
      let u = size.width / 54
      func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: (x - 5) * u, y: (y - 5) * u) }
      var roof = Path()
      roof.move(to: p(13, 30))
      roof.addLine(to: p(32, 15))
      roof.addLine(to: p(51, 30))
      ctx.stroke(roof, with: .color(.black), style: StrokeStyle(lineWidth: 5.4 * u, lineCap: .round, lineJoin: .round))
      for x in [22.5, 35.5] {
        ctx.fill(Path(roundedRect: CGRect(x: (x - 5) * u, y: (33 - 5) * u, width: 6 * u, height: 14 * u), cornerRadius: 3 * u), with: .color(.black))
      }
    }
    .frame(width: 18, height: 18)
    .opacity(dimmed ? 0.45 : 1)
    let r = ImageRenderer(content: view)
    r.scale = 2
    let img = r.nsImage ?? NSImage()
    img.isTemplate = true
    return img
  }
}

/// Draws an app icon from the mark (IconArt) at every size an .iconset needs.
public enum IconRenderer {
  @MainActor
  public static func render(into dir: URL, style: AppIcon = .glow) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
      for scale in [1, 2] {
        let px = base * scale
        let r = ImageRenderer(content: IconArt(style: style, size: CGFloat(px)))
        r.scale = 1
        guard let cg = r.cgImage else { throw CocoaError(.fileWriteUnknown) }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png.write(to: dir.appendingPathComponent(name))
      }
    }
  }
}
