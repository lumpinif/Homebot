// "Reset everything" (Settings and `homebot reset`): the support folder back to a first run.
// Only files inside it are touched, in this order:
//  1. take the gateway owner's lock, so no gateway serves (or opens the activity database)
//     meanwhile; refuse when one runs (the app stops its own first);
//  2. under the store locks (config -> state -> tokens), held to the end: empty tokens.json,
//     state.json and config.json (every Shortcut token, cursor, bot and setting), unread, so a
//     damaged file is reset too; refuse first if a subfolder is a link;
//  3. delete the activity database, the logs, the lab state, the usage-count state, the app's
//     preferences and anything left in the Shortcuts folder;
//  4. only when asked, the saved API key (a Grok Bot login on this Mac is never touched).
// Shortcuts already on an iPhone or Mac stop working: their token is unknown from now on.
import Foundation

public enum Reset {
  public struct ResetError: Error, CustomStringConvertible, Equatable {
    public let description: String
    /// A gateway owns the folder (the app, or `homebot start`).
    public var running = false
    init(_ d: String, running: Bool = false) {
      description = d
      self.running = running
    }
  }

  public struct Report: Sendable, Equatable {
    public var bots: Int
    public var shortcuts: Int
    public var keyRemoved: Bool
  }

  /// The app's own preferences file (AppPrefs, in HomebotUI).
  static let appPrefs = "app.json"

  @discardableResult
  public static func run(_ home: Home, removeKey: Bool, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> Report {
    try home.prepare()
    // A linked folder would lead the deletions out of the support folder: refuse before any
    // change (Codex S19 review).
    for dir in [home.logs, home.shortcuts, home.activity] {
      var st = stat()
      if lstat(dir.path, &st) != 0 { if errno == ENOENT { continue } else { throw ResetError("cannot read \(dir.lastPathComponent)") } }
      guard st.st_mode & S_IFMT == S_IFDIR else { throw ResetError("\(dir.lastPathComponent) in \(home.root.path) is not a plain folder; nothing was reset") }
    }
    guard let owner = try OwnerLock.tryAcquire(home.gatewayLock) else {
      throw ResetError("Homebot is running for \(home.root.path); quit it first, or use Settings › Reset everything in the app", running: true)
    }
    defer { owner.release() }
    // Every store lock, in the stores' order (config -> state -> tokens), for the whole reset: a
    // CLI command that adds a bot or builds a Shortcut meanwhile waits and then sees the empty
    // stores. The files are replaced without being read first, so a damaged one is reset too.
    var locks: [FileLock] = []
    defer { locks.reversed().forEach { $0.release() } }
    for f in [home.config, home.state, home.tokens] { locks.append(try await FileLock.acquire(for: f)) }
    let bots = (try? await ConfigStore(file: home.config).load().bots().count) ?? 0
    let shortcuts = (try? await TokenStore(file: home.tokens).load().list().count) ?? 0
    try FileUtil.writeJSON(home.tokens, TokenFile(tokens: []))
    try FileUtil.writeJSON(home.state, StateData())
    try FileUtil.writeJSON(home.config, ConfigData())

    // The database is closed (no owner serves); its side files go with it.
    for f in ActivityStore(dir: home.activity).files {
      if unlink(f.path) != 0 && errno != ENOENT { throw ResetError("cannot delete \(f.lastPathComponent) (errno \(errno))") }
    }
    // Log lock files stay: a CLI command may be appending right now and holds one.
    try removeContents(home.logs) { !$0.hasSuffix(".lock") }
    try removeContents(home.shortcuts) { _ in true }
    for f in [home.lab, home.usage, home.root.appendingPathComponent(appPrefs)] {
      if unlink(f.path) != 0 && errno != ENOENT { throw ResetError("cannot delete \(f.lastPathComponent) (errno \(errno))") }
    }
    var keyRemoved = false
    if removeKey {
      let c = Credentials(keyFile: home.apiKey, userHome: userHome)
      keyRemoved = FileManager.default.fileExists(atPath: home.apiKey.path)
      try c.removeSaved()
    }
    return Report(bots: bots, shortcuts: shortcuts, keyRemoved: keyRemoved)
  }

  /// Delete the entries of `dir` that `match` selects (a link is deleted, never followed).
  static func removeContents(_ dir: URL, where match: (String) -> Bool) throws {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
    for name in names where match(name) {
      // removeItem deletes a symbolic link itself, not what it points to.
      do {
        try fm.removeItem(at: dir.appendingPathComponent(name))
      } catch {
        throw ResetError("cannot delete \(dir.lastPathComponent)/\(name)")
      }
    }
  }
}
