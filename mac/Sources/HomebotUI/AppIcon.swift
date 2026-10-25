// The app icon the user picks in Settings (S10). macOS has no alternate-icon API for AppKit apps
// (UIApplication.setAlternateIconName is iOS/tvOS only), and writing a custom icon onto the bundle
// (NSWorkspace.setIcon) adds an Icon\r file and a FinderInfo xattr that `codesign --verify
// --strict` rejects. So the running app shows the chosen one through NSApp.applicationIconImage:
// the Dock tile, the app switcher, its alerts. The default is Automatic: White in Light
// appearance, Black in Dark, switching live with the app's appearance.
// The bundle icon (Finder, Spotlight, Login Items, a Dock tile while the app isn't running) is
// App/AppIcon.icon, compiled by actool: White, with a Black variant that macOS 26 shows when the
// user's own Icon & widget style is Dark; macOS 15 shows the White .icns actool writes beside it.
// The three .icns files of the manual choices are drawn by IconRenderer at build time.
import AppKit
import SwiftUI

public enum AppIcon: String, Codable, CaseIterable, Sendable {
  /// The brand: the website logo's colourful light (GlowField).
  case glow
  case black
  case white

  /// The .icns name in Contents/Resources (scripts/build-app.sh).
  public var resource: String {
    switch self {
    case .glow: "Homebot"
    case .black: "Homebot-Black"
    case .white: "Homebot-White"
    }
  }

  var background: Color { self == .white ? .white : .black }
  var foreground: Color { self == .white ? .black : .white }
  /// The hairline that keeps the edge visible on a background of the same colour.
  var rim: Color {
    switch self {
    case .glow: .clear
    case .black: .white.opacity(0.12)
    case .white: .black.opacity(0.08)
    }
  }
}

/// The whole icon canvas: the mark on Apple's icon grid (824 of 1024 points, centred) with the
/// standard soft shadow. Drawn the same way for the .icns files and the Settings thumbnails.
struct IconArt: View {
  let style: AppIcon
  let size: CGFloat

  var body: some View {
    MarkDrawing(size: size * 824 / 1024, style: style)
      .shadow(color: .black.opacity(0.3), radius: size * 10 / 1024, y: size * 10 / 1024)
      .frame(width: size, height: size)
  }
}

/// What the user picked: Automatic (the default) follows the appearance; the others are fixed.
public enum IconChoice: String, Codable, CaseIterable, Sendable {
  case automatic, glow, black, white

  /// The icon shown for this choice in a light or dark appearance.
  public func resolved(dark: Bool) -> AppIcon {
    switch self {
    case .automatic: dark ? .black : .white
    case .glow: .glow
    case .black: .black
    case .white: .white
    }
  }
}

extension IconRenderer {
  /// The image NSApp shows for `icon`: the bundle's .icns, else (a bare `swift run`, the tests)
  /// one drawn now.
  @MainActor
  public static func dockImage(_ icon: AppIcon) -> NSImage? {
    if let cached = drawn[icon] { return cached }
    let image = Bundle.main.image(forResource: icon.resource) ?? {
      let r = ImageRenderer(content: IconArt(style: icon, size: 1024))
      r.scale = 1
      return r.nsImage
    }()
    drawn[icon] = image
    return image
  }

  @MainActor private static var drawn: [AppIcon: NSImage] = [:]
}
