// The Cursor API key Homebot uses (DESIGN §20.4, frozen 2026-10-23). Two sources, in order:
// the saved key (one 0600 file in the support directory), then the BDK login at
// ~/.config/agent-serve/credentials.json, used only when its backendUrl is Cursor's API.
// No environment variables, no other logins. Callers may show or log the source, never the key.
import Foundation

public enum CredentialSource: String, Sendable, Equatable {
  /// The key the user pasted (or set with the CLI from standard input).
  case saved
  /// The BDK login found on this Mac.
  case bdkLogin = "bdk-login"
}

public struct Credential: Sendable, Equatable {
  public let key: String
  public let source: CredentialSource
}

/// What the Account step says about the BDK login on this Mac.
public enum LoginStatus: Sendable, Equatable {
  case none
  case usable
  /// A login exists but was made for another backend (or names none): not used.
  case otherBackend
  /// A login file exists but can't be read as a login (not a regular file, malformed).
  case unreadable
}

public struct Credentials: Sendable {
  public static let cursorBackend = "https://api.cursor.com"

  public let keyFile: URL
  public let userHome: URL

  /// `userHome`: the user's home directory (tests pass a temporary one).
  public init(keyFile: URL, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.keyFile = keyFile
    self.userHome = userHome
  }

  public var loginFile: URL {
    userHome.appendingPathComponent(".config/agent-serve/credentials.json")
  }

  /// The credential to use now, or nil. Read per call, so a change needs no restart.
  public func resolve() throws -> Credential? {
    if let saved = try savedKey() { return Credential(key: saved, source: .saved) }
    if case .usable(let key) = detectLogin() { return Credential(key: key, source: .bdkLogin) }
    return nil
  }

  public func savedKey() throws -> String? {
    guard let data = try FileUtil.readIfExists(keyFile) else { return nil }
    guard let s = String(data: data, encoding: .utf8) else { throw FileUtil.FileError("cannot read \(keyFile.lastPathComponent)") }
    let k = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return k.isEmpty ? nil : k
  }

  /// Save a pasted key (trimmed; refused if empty or not one line).
  public func save(key: String) throws {
    let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !k.isEmpty, !k.contains(where: \.isNewline) else { throw FileUtil.FileError("the key must be one non-empty line") }
    try FileUtil.writePrivateFile(keyFile, k + "\n")
  }

  /// Save a key only if none is saved yet, atomically (a key saved meanwhile is never replaced).
  /// Returns false when a key file already exists.
  public func saveIfAbsent(key: String) throws -> Bool {
    let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !k.isEmpty, !k.contains(where: \.isNewline) else { throw FileUtil.FileError("the key must be one non-empty line") }
    let tmp = keyFile.deletingLastPathComponent().appendingPathComponent(".\(keyFile.lastPathComponent).new-\(Random.hex(bytes: 6))")
    try FileUtil.writePrivateFile(tmp, k + "\n")
    defer { unlink(tmp.path) }
    if link(tmp.path, keyFile.path) == 0 { return true }
    if errno == EEXIST { return false }
    throw FileUtil.FileError("cannot write \(keyFile.lastPathComponent) (errno \(errno))")
  }

  /// Delete the saved key; the BDK login, if usable, applies again.
  public func removeSaved() throws {
    if FileManager.default.fileExists(atPath: keyFile.path) { try FileManager.default.removeItem(at: keyFile) }
  }

  public var loginStatus: LoginStatus {
    switch detectLogin() {
    case .none: return .none
    case .usable: return .usable
    case .otherBackend: return .otherBackend
    case .unreadable: return .unreadable
    }
  }

  enum Detected {
    case none, otherBackend, unreadable
    case usable(String)
  }

  func detectLogin() -> Detected {
    // One open that never follows a symlink and never blocks on a FIFO; the type is checked on
    // the opened descriptor, so the file can't be swapped between the check and the read.
    let fd = open(loginFile.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return errno == ENOENT ? .none : .unreadable }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var st = stat()
    guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= 1_000_000 else { return .unreadable }
    guard let data = try? handle.readToEnd(),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return .unreadable }
    guard let key = (obj["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return .unreadable }
    guard let backend = obj["backendUrl"] as? String, Credentials.isCursorBackend(backend) else { return .otherBackend }
    return .usable(key)
  }

  /// https, host exactly api.cursor.com, no user, port, query or fragment, path empty or "/".
  public static func isCursorBackend(_ s: String) -> Bool {
    guard let c = URLComponents(string: s) else { return false }
    return c.scheme == "https" && c.host == "api.cursor.com" && c.user == nil && c.password == nil && c.port == nil
      && c.query == nil && c.fragment == nil && (c.path.isEmpty || c.path == "/")
  }
}

public enum AcceptedState: String, Sendable, Equatable {
  case unchecked, ok, rejected
}

/// Whether Grok Bot accepted the current credential (DESIGN §20.4 "credential generation"). The
/// state belongs to one generation, which changes whenever the resolved credential's source or
/// key changes (compared in memory only), so a slow check of an old key can never mark a new one
/// `ok`. Callers resolve once per bot turn and report the result with that turn's generation.
public actor CredentialStatus {
  public private(set) var generation = 0
  public private(set) var state: AcceptedState = .unchecked
  private var current: Credential?

  public init() {}

  /// Note the credential just resolved; returns its generation.
  @discardableResult
  public func observe(_ c: Credential?) -> Int {
    if c != current {
      current = c
      generation += 1
      state = .unchecked
    }
    return generation
  }

  /// Record a check's result; ignored when the credential changed since (returns false).
  /// `onlyIfUnchecked`: a background check (the app's launch check) never replaces a result
  /// that arrived while it was out, such as a Siri request Grok Bot refused.
  @discardableResult
  public func record(generation g: Int, accepted: Bool, onlyIfUnchecked: Bool = false) -> Bool {
    guard g == generation, current != nil, !onlyIfUnchecked || state == .unchecked else { return false }
    state = accepted ? .ok : .rejected
    return true
  }

  /// Forget every result (Reset everything): even a kept key is unchecked again, and a check
  /// still out for it is ignored.
  public func reset() {
    current = nil
    generation += 1
    state = .unchecked
  }

  public var source: CredentialSource? { current?.source }
}
