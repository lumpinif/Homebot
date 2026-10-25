// The app's look: the system's own semantic colours (window background, label colours, the user's
// accent colour, system green/red/orange), so every view follows light and dark mode, Increase
// Contrast and the accent colour chosen in System Settings, the way first-party apps do. Plus the
// spacing every view shares, so all blocks in a view line up on the same edges.
import AppKit
import SwiftUI

extension Color {
  /// A colour with a light and a dark value, resolved by the view's appearance.
  static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: (CGFloat, CGFloat) = (1, 1)) -> Color {
    Color(nsColor: NSColor(name: nil) { a in
      let isDark = a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      let v = isDark ? dark : light
      return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: isDark ? alpha.1 : alpha.0)
    })
  }

  static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
    Color(.sRGB, red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255, opacity: a)
  }
}

enum Theme {
  /// The window's own background: the canvas every page sits on, also under the toolbar.
  static let background = Color(nsColor: .windowBackgroundColor)
  /// A grouped section's fill, as in System Settings: a step lighter than the canvas in dark
  /// mode, a quiet tint of it in light mode.
  static let card = Color(nsColor: .quaternarySystemFill)
  static let foreground = Color.primary
  static let muted = Color.secondary
  /// Small neutral shapes: icon tiles, step numbers not reached yet, path chips.
  static let fill = Color(nsColor: .tertiarySystemFill)
  /// Hairlines between rows and around inputs.
  static let border = Color(nsColor: .separatorColor)
  static let primary = Color.accentColor
  static let success = Color(nsColor: .systemGreen)
  static let destructive = Color(nsColor: .systemRed)
  static let warning = Color(nsColor: .systemOrange)
  /// Hover and pressed fills, as the system sidebar and menus draw them (colour only).
  static let hover = Color.primary.opacity(0.06)
  static let active = Color.primary.opacity(0.1)

  /// The content column every page uses, and the gaps between its blocks.
  static let column: CGFloat = 600
  static let gap: CGFloat = 28
  static let rowGap: CGFloat = 12
  /// Grouped sections and rows (System Settings' inset groups).
  static let radius: CGFloat = 12
  /// An inline (i) or (?) button's width: its 13 pt symbol and a hair either side.
  static let infoButton: CGFloat = 16
  /// Padding around a page's column.
  static let pagePadding: CGFloat = 32
}

/// The step header tiles' gradients (web pieces.tsx tints).
enum Tint {
  static let account = [Color.hex(0x38bdf8), .hex(0x2563eb)]
  static let language = [Color.hex(0xa78bfa), .hex(0x4f46e5)]
  static let bot = [Color.hex(0x34d399), .hex(0x0d9488)]
  static let shortcut = [Color.hex(0xf472b6), .hex(0xc026d3)]
  static let phone = [Color.hex(0xa1a1aa), .hex(0x3f3f46)]
  static let home = [Color.hex(0xfb923c), .hex(0xea580c)]
  static let settings = [Color.hex(0x9ca3af), .hex(0x4b5563)]
}

/// Reduce Motion (System Settings › Accessibility › Display): movement and scaling become plain
/// fades. Read where no view environment is at hand (transitions, withAnimation).
@MainActor
enum Motion {
  static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  /// `t` normally, a fade under Reduce Motion.
  static func transition(_ t: AnyTransition) -> AnyTransition { reduced ? .opacity : t }

  /// Page changes and the sidebar selection: quick and settled, like the system's own sidebar.
  static let snappy = Animation.snappy(duration: 0.24)
}
