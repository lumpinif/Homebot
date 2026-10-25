// The support directory (DESIGN §20.5 T0): ~/Library/Application Support/Homebot by default,
// 0700, never inside a git work tree (it holds secrets, which would then show in `git status`).
// Ported from src/core/home.ts; the location and file names follow DESIGN §20.
import Foundation

public struct Home: Sendable, Equatable {
  public let root: URL

  public var config: URL { root.appendingPathComponent("config.json") }
  public var state: URL { root.appendingPathComponent("state.json") }
  public var tokens: URL { root.appendingPathComponent("tokens.json") }
  /// The saved Cursor API key (DESIGN §20.4): the key only, one 0600 file.
  public var apiKey: URL { root.appendingPathComponent("api-key") }
  public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
  public var shortcuts: URL { root.appendingPathComponent("Shortcuts", isDirectory: true) }
  /// The activity database's directory (DESIGN §20.6 A5; the store itself is built in S2).
  public var activity: URL { root.appendingPathComponent("Activity", isDirectory: true) }
  /// The lab's chosen experiment (DESIGN §19.1).
  public var lab: URL { root.appendingPathComponent("lab.json") }
  /// Opt-in usage counts and update check state (Usage.swift); local only.
  public var usage: URL { root.appendingPathComponent("usage.json") }
  /// The gateway owner's lock (DESIGN §20.6 A5): held by the process that serves the LAN.
  public var gatewayLock: URL { root.appendingPathComponent("gateway.lock") }
  /// The owner's local control channel (A5): a user-only Unix socket.
  public var controlSocket: URL { root.appendingPathComponent("control.sock") }

  /// The default location for the current user.
  public static func defaultRoot() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Homebot", isDirectory: true)
  }

  /// `root` overrides the default (tests, and a later CLI flag). `allowInGit` is for tests only.
  public init(root: URL? = nil, allowInGit: Bool = false) throws {
    let r = (root ?? Home.defaultRoot()).standardizedFileURL
    // Checked on the path as given and with symlinks resolved, so a link can't lead the
    // secrets into a repository.
    if !allowInGit, let git = Home.findGitRoot(r) ?? Home.findGitRoot(r.resolvingSymlinksInPath()) {
      throw FileUtil.FileError("The Homebot folder (\(r.path)) is inside a git work tree (\(git.path)). Homebot stores secrets there; choose a folder outside any repository.")
    }
    self.root = r
  }

  /// The git work-tree root containing `dir`, if any.
  public static func findGitRoot(_ dir: URL) -> URL? {
    var cur = dir.standardizedFileURL.path
    while true {
      if FileManager.default.fileExists(atPath: (cur as NSString).appendingPathComponent(".git")) { return URL(fileURLWithPath: cur, isDirectory: true) }
      // String-based: URL.deletingLastPathComponent() on "/" yields "/..", never reaching a fixpoint.
      let up = (cur as NSString).deletingLastPathComponent
      if up == cur || up.isEmpty { return nil }
      cur = up
    }
  }

  /// Create the private layout and clean up after interrupted writes.
  public func prepare() throws {
    try FileUtil.ensurePrivateDir(root)
    try FileUtil.ensurePrivateDir(logs)
    try FileUtil.ensurePrivateDir(shortcuts)
    FileUtil.sweepTempFiles(root)
    FileUtil.sweepTempFiles(shortcuts)
  }
}
