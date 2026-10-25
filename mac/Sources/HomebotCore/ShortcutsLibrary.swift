// The user's Shortcuts library on this Mac, as `/usr/bin/shortcuts list` prints it: one name per
// line. Apple's command has no import, delete or rename, and tells nothing about iCloud, so this
// only answers "is a Shortcut named X on this Mac?" (DESIGN §7.9). Tested on macOS 26: a Shortcut
// added in the Shortcuts app is listed within two seconds.
import Foundation

public enum ShortcutsLibrary {
  /// The names in `shortcuts list` output, in order. Empty lines are skipped.
  public static func parse(_ output: String) -> [String] {
    output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
  }

  /// A Shortcut with exactly this name (Unicode-normalized; Siri hears the name as it is).
  public static func has(_ names: [String], _ name: String) -> Bool {
    names.contains { $0.precomposedStringWithCanonicalMapping == name.precomposedStringWithCanonicalMapping }
  }

  /// Copies the Shortcuts app renamed because the name was taken: "<name> 1", "<name> 2". On
  /// macOS 26 with iCloud, adding a Shortcut over one of the same name (even with "Replace") can
  /// leave only renamed copies, and Siri no longer finds the phrase.
  public static func renamedCopies(_ names: [String], _ name: String) -> [String] {
    let base = name.precomposedStringWithCanonicalMapping + " "
    return names.filter { n in
      let m = n.precomposedStringWithCanonicalMapping
      guard m.hasPrefix(base) else { return false }
      let rest = m.dropFirst(base.count)
      return !rest.isEmpty && rest.allSatisfy(\.isASCII) && rest.allSatisfy(\.isNumber)
    }
  }

  /// Runs `shortcuts list`; nil when it fails (it sometimes answers "Couldn't communicate with a
  /// helper application."), so an unknown library is never taken for an empty one.
  public static func list(command: String = "/usr/bin/shortcuts") async -> [String]? {
    await Task.detached { () -> [String]? in
      let p = Process()
      p.executableURL = URL(fileURLWithPath: command)
      p.arguments = ["list"]
      let out = Pipe()
      p.standardOutput = out
      p.standardError = FileHandle.nullDevice
      do { try p.run() } catch { return nil }
      let data = out.fileHandleForReading.readDataToEndOfFile()
      p.waitUntilExit()
      guard p.terminationStatus == 0 else { return nil }
      return parse(String(decoding: data, as: UTF8.self))
    }.value
  }
}
