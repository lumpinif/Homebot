// The app icon choice (S10, Automatic since S15): it is saved in app.json, survives a restart,
// tolerates an old or unknown file, follows the appearance when Automatic, and each variant draws
// what its name says.
import AppKit
import Foundation
import SwiftUI
import Testing

import HomebotCore
@testable import HomebotUI

@MainActor
@Suite struct AppIconTests {
  func env(_ root: URL) -> AppEnv {
    var env = AppEnv()
    env.home = root.appendingPathComponent("hb", isDirectory: true)
    env.userHome = root
    env.port = 0
    env.bind = "127.0.0.1"
    env.fakeLoginItem = true
    return env
  }

  @Test func automaticIsTheDefaultAndFollowsTheAppearance() throws {
    #expect(AppPrefs().icon == .automatic)
    #expect(IconChoice.automatic.resolved(dark: false) == .white)
    #expect(IconChoice.automatic.resolved(dark: true) == .black)
    // An explicit choice wins in both appearances.
    for (c, i) in [(IconChoice.glow, AppIcon.glow), (.black, .black), (.white, .white)] {
      #expect(c.resolved(dark: false) == i && c.resolved(dark: true) == i)
    }
  }

  /// Files from before Automatic: "appIcon" was always written, Glow by default, so Glow means
  /// never picked (Automatic); Black and White were picked and stay. "icon" wins when present.
  @Test func oldFilesMoveToAutomaticUnlessAChoiceWasMade() throws {
    func load(_ json: String) throws -> AppPrefs { try JSONDecoder().decode(AppPrefs.self, from: Data(json.utf8)) }
    let none = try load(#"{"keepAwake":false,"appearance":"dark"}"#)
    #expect(none.icon == .automatic && none.appearance == .dark)
    #expect(try load(#"{"appIcon":"glow"}"#).icon == .automatic)
    #expect(try load(#"{"appIcon":"black"}"#).icon == .black)
    #expect(try load(#"{"appIcon":"white"}"#).icon == .white)
    #expect(try load(#"{"appIcon":"white","icon":"glow"}"#).icon == .glow)
    // A value from a newer version falls back to Automatic and keeps the rest.
    let newer = try load(#"{"keepAwake":false,"icon":"rainbow"}"#)
    #expect(newer.icon == .automatic && newer.keepAwake == false)
  }

  @Test func theChoiceIsSavedAndReadAtTheNextLaunch() throws {
    let root = try shortDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let m = try AppModel(env: env(root))
    #expect(m.prefs.icon == .automatic)
    m.setAppIcon(.glow)
    #expect(m.prefs.icon == .glow)
    let json = try String(contentsOf: AppPrefs.file(m.home), encoding: .utf8)
    #expect(json.contains(#""icon":"glow""#) || json.contains(#""icon" : "glow""#))

    let again = try AppModel(env: env(root))
    #expect(again.prefs.icon == .glow, "an explicit Glow is kept, not read as never picked")
    again.setAppIcon(.automatic)
    #expect(AppPrefs.load(again.home).icon == .automatic)
  }

  @Test func everyIconHasAnImage() throws {
    for icon in AppIcon.allCases {
      let img = try #require(IconRenderer.dockImage(icon))
      #expect(img.size.width >= 512)
    }
  }

  @Test func eachVariantDrawsItsColours() throws {
    let root = try shortDir()
    defer { try? FileManager.default.removeItem(at: root) }
    for icon in AppIcon.allCases {
      let dir = root.appendingPathComponent("\(icon.resource).iconset")
      try IconRenderer.render(into: dir, style: icon)
      let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
      #expect(files.count == 10)
      #expect(files.contains("icon_512x512@2x.png"))
      let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: dir.appendingPathComponent("icon_512x512@2x.png"))))
      #expect(rep.pixelsWide == 1024)
      // Inside the mark, above the eyes (background), and the bottom centre.
      let back = try #require(rep.colorAt(x: 300, y: 300)?.usingColorSpace(.sRGB))
      let low = try #require(rep.colorAt(x: 512, y: 880)?.usingColorSpace(.sRGB))
      // The corner is outside the squircle: clear in every variant.
      #expect(try #require(rep.colorAt(x: 4, y: 4)).alphaComponent < 0.01)
      switch icon {
      case .glow:
        #expect(back.saturationComponent > 0.3 && back.brightnessComponent > 0.2)
        #expect(low.saturationComponent > 0.2)
      case .black:
        #expect(back.brightnessComponent < 0.05)
        #expect(low.brightnessComponent < 0.05)
      case .white:
        #expect(back.brightnessComponent > 0.95 && back.saturationComponent < 0.05)
        #expect(low.brightnessComponent > 0.95)
      }
    }
  }

  /// Glow is the website logo's frame from S17's master (.agent-logs/s17-glow-icon,
  /// homebot-glow-1024.png): the full-bleed drawing matches the master's sRGB values at five
  /// points (dark corner, blue side, red side, bottom edge, under the roof) within 8/255.
  @Test func glowMatchesTheMaster() throws {
    let r = ImageRenderer(content: MarkDrawing(size: 1024, style: .glow).clipShape(Rectangle()))
    r.scale = 1
    let rep = NSBitmapImageRep(cgImage: try #require(r.cgImage))
    let master: [(Int, Int, UInt32)] = [(100, 100, 0x08061b), (150, 700, 0x17265c), (820, 420, 0xbc425e), (512, 960, 0x683249), (512, 420, 0xbe6250)]
    for (x, y, hex) in master {
      let c = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
      let want = [Double(hex >> 16 & 0xff), Double(hex >> 8 & 0xff), Double(hex & 0xff)]
      let got = [c.redComponent, c.greenComponent, c.blueComponent].map { Double($0) * 255 }
      #expect(zip(want, got).allSatisfy { abs($0 - $1) <= 8 }, "(\(x), \(y)): \(got) vs \(want)")
    }
  }
}
