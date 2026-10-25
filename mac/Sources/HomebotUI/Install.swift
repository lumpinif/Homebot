// The Install step's rules (S16): where the user installs a Shortcut (this Mac, from which iCloud
// brings it to the iPhone, or the iPhone directly), and what each row of the This Mac path shows.
// Pure values, tested without a window (InstallStateTests).
import Foundation
import HomebotCore

/// Where the user installs Shortcuts. Asked once ("Does your iPhone use the same Apple Account as
/// this Mac?"); nil until then. No public API tells whether iCloud Sync for Shortcuts is on or
/// which Apple Account is signed in, so the user answers.
public enum InstallTarget: String, Codable, Sendable, CaseIterable {
  case mac, iphone
}

/// Step 1 of the This Mac path: getting the file into the Shortcuts app on this Mac.
public enum MacAddState: Equatable, Sendable {
  /// No file to add (expired, used elsewhere, or made before this run without one): make a new copy.
  case needsFile
  /// The file is unsigned: Shortcuts adds only signed Shortcuts.
  case needsSigning
  /// Another Shortcut already has this name. Adding over it can leave only renamed copies
  /// ("<name> 1"), which Siri doesn't find, so the old one is removed first.
  case nameTaken
  /// Ready: "Add to Shortcuts".
  case ready
  /// In the Shortcuts library under its name.
  case added
  /// Shortcuts renamed it ("<name> 1"): Siri needs the exact name.
  case renamed(String)
}

public enum InstallState {
  /// - `library`: the names `shortcuts list` printed; nil when it could not be read.
  /// - `opened`: the user clicked "Add to Shortcuts" for this Shortcut (so a Shortcut with its
  ///   name is this one, not an older one).
  /// - `onDevice`: the token was used or answered, so a Shortcut with its name is this one.
  public static func macAdd(name: String, hasFile: Bool, signed: Bool, opened: Bool, onDevice: Bool, library: [String]?) -> MacAddState {
    if let names = library {
      if let copy = ShortcutsLibrary.renamedCopies(names, name).first, opened || onDevice { return .renamed(copy) }
      if ShortcutsLibrary.has(names, name) { return opened || onDevice ? .added : .nameTaken }
    } else if onDevice {
      return .added
    }
    if !hasFile { return onDevice ? .added : .needsFile }
    return signed ? .ready : .needsSigning
  }
}

extension ShortcutList {
  /// The rows the Shortcuts page shows: working ones and ones on their way. Retired ones are hidden
  /// (S16 D4), and so is a copy that was never used and whose file is gone: it can't be installed
  /// any more and expires on its own (DESIGN §7.7).
  static func visible(_ tokens: [TokenView]) -> [TokenView] {
    live(tokens).filter { !($0.state == .pending && $0.usedAt == nil && !$0.hasFile) }
  }
}

/// Apple's documented Shortcuts URLs (Shortcuts User Guide for Mac, "Open, create and run a
/// shortcut from a URL").
public enum ShortcutsURL {
  public static func open(_ name: String) -> URL? { url("open-shortcut", name) }
  public static func run(_ name: String) -> URL? { url("run-shortcut", name) }

  static func url(_ action: String, _ name: String) -> URL? {
    // Every character that has a meaning in a query is encoded, so any name comes through whole.
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    guard let n = name.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
    return URL(string: "shortcuts://\(action)?name=\(n)")
  }
}

public enum ShortcutFile {
  /// A file Apple signed: an Apple Encrypted Archive ("AEA1"). Shortcuts adds only those.
  public static func isSigned(_ url: URL) -> Bool {
    guard let h = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? h.close() }
    return (try? h.read(upToCount: 4)) == Data("AEA1".utf8)
  }
}
