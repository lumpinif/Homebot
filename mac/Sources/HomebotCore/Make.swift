// Build one Shortcut file: issue a pending token for its bot set and Siri language, write the
// token-bearing plist as a short-lived 0600 artifact (deleted on first use / revoke / expiry /
// 24 h by TokenStore), optionally sign it. Ported from src/shortcut/make.ts.
import Foundation

public enum ShortcutKind: Sendable, Equatable {
  /// A per-bot voice Shortcut (Ask for Input → POST → Speak).
  case ask
  /// A voice Shortcut that keeps listening after each answer (DESIGN §18, experimental).
  case conversation
  /// One phrase for a set of bots; Siri asks which one (DESIGN §20.5).
  case entry
  /// The wait-limit test (DESIGN §7.6).
  case probe
  /// The device-experiment Shortcut (DESIGN §19.1).
  case lab

  var tokenKind: TokenKind {
    switch self {
    case .ask, .conversation, .entry: .ask
    case .probe: .probe
    case .lab: .lab
    }
  }

  var mode: ShortcutMode? {
    switch self {
    case .ask: .single
    case .conversation: .conversation
    case .entry: .entry
    case .probe, .lab: nil
    }
  }
}

public struct MadeShortcut: Sendable, Equatable {
  public let tokenId: String
  public let file: URL
  public let name: String
  public let signed: Bool
}

/// The signer a build uses; tests pass a fake. nil = don't sign.
public typealias SignFn = @Sendable (_ input: String, _ output: String) async throws -> Void

public enum ShortcutMaker {
  /// A display name made safe as one path segment: no separators, control characters or leading
  /// dots, at most 60 characters (code points).
  public static func safeFileName(_ name: String) -> String {
    var s = name.replacingOccurrences(of: #"[/\\:\x{00}-\x{1F}\x{7F}]"#, with: "_", options: .regularExpression)
    s = s.replacingOccurrences(of: #"^[.\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+"#, with: "_", options: .regularExpression)
    s = s.trimmingCharacters(in: jsWhitespace)
    var v = String.UnicodeScalarView()
    v.append(contentsOf: s.unicodeScalars.prefix(60))
    let r = String(v)
    return r.isEmpty ? "Homebot" : r
  }

  /// The Mac's Bonjour name (DESIGN D10), e.g. "felix-mac" -> http://felix-mac.local:8787.
  public static func localHostName() -> String {
    if let name = SCLocalHostName.read(), !name.isEmpty { return name }
    let h = ProcessInfo.processInfo.hostName
    return h.hasSuffix(".local") ? String(h.dropLast(6)) : h
  }

  public struct MakeError: Error, CustomStringConvertible, Equatable {
    public let description: String
  }

  /// Non-secret inputs are checked before a token exists. After that, any failure (encoding,
  /// disk, signing) deletes the token's directory and revokes the new token; the token being
  /// replaced is untouched (it is only retired by the new token's first answered request).
  public static func make(
    tokens: TokenStore, lifecycle: BotLifecycle?, bots: [Bot], profile: ShortcutProfile, baseUrl: String,
    kind: ShortcutKind = .ask, replaces: String? = nil, otherAccount: Bool = false, sign: SignFn? = nil, builder: ShortcutBuilder = ShortcutBuilder()
  ) async throws -> MadeShortcut {
    guard let url = URLComponents(string: baseUrl), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host?.isEmpty == false else {
      throw MakeError(description: "gateway URL must be http(s)://host:port, got \"\(baseUrl)\"")
    }
    guard let first = bots.first else { throw MakeError(description: "a Shortcut needs at least one bot") }
    if kind == .entry {
      guard bots.count <= TokenStore.maxBots else { throw MakeError(description: "a Shortcut can answer for at most \(TokenStore.maxBots) bots") }
      guard Set(bots.map(\.key)).count == bots.count else { throw MakeError(description: "a bot is listed twice") }
    } else if bots.count != 1 {
      throw MakeError(description: "this Shortcut is for one bot; use the entry Shortcut for several")
    }
    // Only blocking problems refuse a voice Shortcut (DESIGN §16.2): a name iOS would change, or
    // one in use. Recognition risks are advice.
    let blocking = profile.problems.filter(\.blocking)
    if kind.tokenKind == .ask && !blocking.isEmpty { throw MakeError(description: blocking.map(\.message).joined(separator: " ")) }
    // iOS names an imported Shortcut after its FILE name, so the effective Siri phrase is the
    // sanitized file name; it is also the name the setup steps tell the user to run.
    let name = safeFileName(kind == .probe ? profile.probeName : kind == .lab ? profile.labName : profile.name)
    let siriLang = profile.siriLang
    let tokenKind = kind.tokenKind
    let mode = kind.mode
    let issue: @Sendable ([Bot]) async throws -> (id: String, token: String) = { current in
      try await tokens.issue(bots: current.map { BotGrant(key: $0.key, sessionId: $0.sessionId) }, label: name, replaces: replaces, siriLang: siriLang, kind: tokenKind, mode: mode, uniqueLabel: true, otherAccount: otherAccount)
    }
    let (id, token): (String, String)
    if let lifecycle { (id, token) = try await lifecycle.issueFor(bots, issue) } else { (id, token) = try await issue(bots) }
    let dir = try tokens.artifactDir(id)
    do {
      let plist: PlistValue
      switch kind {
      case .probe: plist = try builder.probeShortcut(baseUrl: baseUrl, token: token, speakLang: profile.speakLang)
      case .lab: plist = try builder.labShortcut(baseUrl: baseUrl, token: token, speakLang: profile.speakLang)
      case .entry: plist = try builder.entryShortcut(baseUrl: baseUrl, token: token, speakLang: profile.speakLang)
      case .conversation: plist = try builder.conversationShortcut(baseUrl: baseUrl, botKey: first.key, token: token, prompt: profile.prompt, speakLang: profile.speakLang)
      case .ask: plist = try builder.askShortcut(baseUrl: baseUrl, botKey: first.key, token: token, prompt: profile.prompt, speakLang: profile.speakLang)
      }
      let unsigned = dir.appendingPathComponent("\(name).unsigned.shortcut")
      try FileUtil.writePrivateFile(unsigned, try Plist.xml(plist))
      // Another process may have revoked the token (or removed its bot) while the file was being
      // written or signed: then the file is deleted and the build fails, never leaving a
      // token-bearing file for a dead token.
      let stillPending = {
        guard try await tokens.isPendingUsable(id) else { throw MakeError(description: "the Shortcut's token was revoked while it was being built; nothing was kept") }
      }
      try await stillPending()
      guard let sign else {
        try await tokens.supersedeUnused(by: id)
        return MadeShortcut(tokenId: id, file: unsigned, name: name, signed: false)
      }
      let signed = dir.appendingPathComponent("\(name).shortcut")
      defer { try? FileManager.default.removeItem(at: unsigned) }
      try await sign(unsigned.path, signed.path)
      chmod(signed.path, 0o600) // the signer runs with umask 077 already; this covers custom signers
      try await stillPending()
      try await tokens.supersedeUnused(by: id)
      return MadeShortcut(tokenId: id, file: signed, name: name, signed: true)
    } catch {
      try? FileManager.default.removeItem(at: dir)
      _ = try? await tokens.revoke(id)
      throw error
    }
  }
}

/// `scutil --get LocalHostName`, run with an argument array.
enum SCLocalHostName {
  static func read() -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
    p.arguments = ["--get", "LocalHostName"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
