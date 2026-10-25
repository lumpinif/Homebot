// Import from the TypeScript version's folder, ~/.homebot (DESIGN §20.4, §20.5 T2, §20.11 B8):
// one store after import, never two writers. In order:
//  1. refuse while anything listens on the old gateway's ports (it must be stopped first), or
//     while a gateway owns the new folder;
//  2. refuse a symlinked folder or file (every file is opened without following links and must
//     be a regular file);
//  3. take the old version's own locks (O_EXCL `<file>.lock`, as its withFileLock does) so a
//     TypeScript command can't write meanwhile, and the new folder's locks;
//  4. copy bots, settings (without `logText` and `setupPort`, which no longer exist), cursors and
//     tokens (migrated by T2; sessionless tokens only when the user chose to keep them), and the
//     key from `secrets.json` once into `api-key`;
//  5. mark the old folder as moved (`MOVED`), so the TypeScript CLI refuses to run on it.
// The old files are otherwise left as they are. No secret is printed or logged.
import Foundation

public enum TSImport {
  public static let markerName = "MOVED"
  /// TypeScript's withFileLock breaks a lock older than this; ours is kept fresher.
  static let tsStaleMs: Double = 10_000

  public struct ImportError: Error, CustomStringConvertible, Equatable {
    public let description: String
    /// The old gateway is still running (its ports answer, or gateway.pid names a live process);
    /// the app says "stop it first" in the user's language.
    public var oldGatewayRunning = false
    init(_ d: String, oldGatewayRunning: Bool = false) {
      description = d
      self.oldGatewayRunning = oldGatewayRunning
    }
  }

  /// What the old folder holds (read-only).
  public struct Preview: Sendable, Equatable {
    public struct Token: Sendable, Equatable {
      public var id: String
      public var label: String
      public var bot: String
      public var state: String
      /// Made before M4: imported retired unless the user keeps it (T2).
      public var sessionless: Bool
    }

    public var bots: [Bot]
    public var tokens: [Token]
    public var hasKey: Bool
    /// The old gateway's ports (voice, setup page).
    public var ports: [Int]
    public var moved: Bool
  }

  public struct Report: Sendable, Equatable {
    public var bots: Int
    public var cursors: Int
    public var usable: Int
    public var retired: Int
    public var keyCopied: Bool
  }

  /// The default old folder: ~/.homebot.
  public static func defaultSource(userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    userHome.appendingPathComponent(".homebot", isDirectory: true)
  }

  /// Whether something accepts TCP connections on 127.0.0.1:port.
  public static func listening(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
  }

  // MARK: Reading the old folder

  static func checkFolder(_ dir: URL) throws {
    var st = stat()
    guard lstat(dir.path, &st) == 0 else { throw ImportError("no TypeScript Homebot folder at \(dir.path)") }
    guard st.st_mode & S_IFMT != S_IFLNK else { throw ImportError("\(dir.path) is a symbolic link; refusing to import through it") }
    guard st.st_mode & S_IFMT == S_IFDIR else { throw ImportError("\(dir.path) is not a folder") }
    guard st.st_uid == getuid() else { throw ImportError("\(dir.path) belongs to another user") }
  }

  /// A file's bytes, or nil if it does not exist. Links, non-regular files and huge files are refused.
  static func read(_ file: URL) throws -> Data? {
    let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    if fd < 0 {
      if errno == ENOENT { return nil }
      if errno == ELOOP { throw ImportError("\(file.lastPathComponent) is a symbolic link; refusing to import it") }
      throw ImportError("cannot read \(file.lastPathComponent)")
    }
    let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var st = stat()
    guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw ImportError("\(file.lastPathComponent) is not a regular file") }
    guard st.st_size <= 20_000_000 else { throw ImportError("\(file.lastPathComponent) is too large") }
    guard let data = try? h.readToEnd() else { throw ImportError("cannot read \(file.lastPathComponent)") }
    return data
  }

  /// Parse JSON; the error never quotes content (these files hold secrets).
  static func json(_ file: URL) throws -> [String: Any] {
    guard let data = try read(file) else { return [:] }
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ImportError("\(file.lastPathComponent) is not valid JSON") }
    return obj
  }

  static func decode<T: Decodable>(_ type: T.Type, _ file: URL) throws -> T? {
    guard let data = try read(file) else { return nil }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw ImportError("\(file.lastPathComponent) is not valid JSON")
    }
  }

  struct Old {
    var config: ConfigData
    var state: StateData
    var tokens: [[String: Any]]
    var key: String?
    var ports: [Int]
  }

  static func load(_ dir: URL) throws -> Old {
    let config = try decode(ConfigData.self, dir.appendingPathComponent("config.json")) ?? ConfigData()
    let state = try decode(StateData.self, dir.appendingPathComponent("state.json")) ?? StateData()
    let tokens = (try json(dir.appendingPathComponent("tokens.json"))["tokens"] as? [[String: Any]]) ?? []
    let secrets = try json(dir.appendingPathComponent("secrets.json"))
    let key = (secrets["bdkApiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let raw = try json(dir.appendingPathComponent("config.json"))["settings"] as? [String: Any] ?? [:]
    let port = (raw["port"] as? NSNumber)?.intValue ?? 8787
    let setup = (raw["setupPort"] as? NSNumber)?.intValue ?? 8788
    return Old(config: config, state: state, tokens: tokens, key: key?.isEmpty == false ? key : nil, ports: [port, setup])
  }

  public static func preview(_ dir: URL) throws -> Preview {
    try checkFolder(dir)
    let old = try load(dir)
    let bots = old.config.bots.keys.sorted().compactMap { old.config.bots[$0]?.bot($0) }
    let toks = old.tokens.compactMap { t -> Preview.Token? in
      guard let id = t["id"] as? String, let bot = t["bot"] as? String else { return nil }
      return Preview.Token(id: id, label: t["label"] as? String ?? "", bot: bot, state: t["state"] as? String ?? "", sessionless: t["sessionId"] == nil)
    }
    let moved = FileManager.default.fileExists(atPath: dir.appendingPathComponent(markerName).path)
    return Preview(bots: bots, tokens: toks, hasKey: old.key != nil, ports: old.ports, moved: moved)
  }

  /// The process id of a running TypeScript gateway (its gateway.pid names a live process).
  static func runningGateway(_ dir: URL) throws -> Int32? {
    guard let data = try read(dir.appendingPathComponent("gateway.pid")),
          let pid = Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
    return kill(pid, 0) == 0 || errno == EPERM ? pid : nil
  }

  // MARK: The old version's locks

  /// The TypeScript lock: `<file>.lock` created with O_EXCL; its holder deletes it. A lock left by
  /// a crashed TypeScript command (older than 10 s) is broken, as TypeScript itself does.
  final class TSLock: @unchecked Sendable {
    let path: String
    private var keeper: Task<Void, Never>?

    init(_ file: URL, timeoutMs: Double = 3000) async throws {
      path = file.path + ".lock"
      let start = Date()
      while true {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd >= 0 {
          close(fd)
          break
        }
        guard errno == EEXIST else { throw ImportError("cannot lock \(file.lastPathComponent) (errno \(errno))") }
        if let age = FileUtil.ageMs(URL(fileURLWithPath: path), now: Date().timeIntervalSince1970 * 1000), age > TSImport.tsStaleMs {
          unlink(path)
          continue
        }
        if Date().timeIntervalSince(start) * 1000 > timeoutMs { throw ImportError("the TypeScript version is busy (\(file.lastPathComponent).lock); try again") }
        try await Task.sleep(nanoseconds: 15_000_000)
      }
      // Keep the lock young, so a TypeScript command never takes it as stale while we copy.
      let p = path
      keeper = Task.detached {
        while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: 2_000_000_000)
          utimes(p, nil)
        }
      }
    }

    func release() {
      keeper?.cancel()
      unlink(path)
    }
  }

  // MARK: Import

  /// - `keep`: ids of sessionless tokens the user chose to keep for their bot (T2).
  /// - `isListening`: tests replace the port check.
  @discardableResult
  public static func run(from dir: URL, to home: Home, keep: Set<String> = [], now: Double = Date().timeIntervalSince1970 * 1000, isListening: (Int) -> Bool = TSImport.listening) async throws -> Report {
    try checkFolder(dir)
    if FileManager.default.fileExists(atPath: dir.appendingPathComponent(markerName).path) {
      throw ImportError("\(dir.path) was already imported (it is marked as moved)")
    }
    let first = try load(dir)
    for p in first.ports where isListening(p) {
      throw ImportError("something is listening on port \(p): the old Homebot gateway may still be running. Stop it first (Ctrl-C in its terminal), then import again.", oldGatewayRunning: true)
    }
    try home.prepare()
    guard let owner = try OwnerLock.tryAcquire(home.gatewayLock) else {
      throw ImportError("Homebot is running for \(home.root.path); quit it before importing")
    }
    defer { owner.release() }
    // Claim the old folder first, with an exclusive create: a second import, and every
    // TypeScript command from now on, sees the marker. Then look for a running TypeScript
    // gateway: it writes gateway.pid before it checks for the marker, so one of the two always
    // sees the other.
    let marker = dir.appendingPathComponent(markerName)
    let mfd = open(marker.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard mfd >= 0 else {
      if errno == EEXIST { throw ImportError("\(dir.path) was already imported (it is marked as moved)") }
      throw ImportError("cannot mark \(dir.path) as moved (errno \(errno))")
    }
    _ = "{\"importing\":true}\n".withCString { write(mfd, $0, strlen($0)) }
    close(mfd)
    // What the new store held before (nil: no file), restored if the import fails, so it can be
    // tried again.
    var before: [(URL, Data?)] = []
    var done = false
    defer {
      if !done {
        for (f, d) in before {
          if let d { try? FileUtil.writePrivateFile(f, d) } else { unlink(f.path) }
        }
        unlink(marker.path)
      }
    }
    if let pid = try runningGateway(dir) {
      throw ImportError("the old Homebot gateway is running (process \(pid)). Stop it first (Ctrl-C in its terminal), then import again.", oldGatewayRunning: true)
    }
    // Old locks, in the old lock order (config, then state and tokens).
    var held: [TSLock] = []
    defer { held.reversed().forEach { $0.release() } }
    for name in ["config.json", "state.json", "tokens.json"] { held.append(try await TSLock(dir.appendingPathComponent(name))) }
    // Re-read under the locks: this is what gets copied.
    let old = try load(dir)

    let config = ConfigStore(file: home.config)
    let state = StateStore(file: home.state)
    let tokens = TokenStore(file: home.tokens, artifactsDir: home.shortcuts)
    let cfgLock = try await FileLock.acquire(for: home.config)
    defer { cfgLock.release() }
    try await config.load()
    try await state.load()
    try await tokens.load()
    guard await config.bots().isEmpty, await tokens.records.isEmpty else {
      throw ImportError("Homebot already has bots or Shortcuts in \(home.root.path); import only into a new setup")
    }
    before = try [home.config, home.state, home.tokens].map { ($0, try FileUtil.readIfExists($0)) }

    // Bots and settings (validated like any bot; unknown settings are dropped by the decoder).
    var cfg = ConfigData()
    for (k, entry) in old.config.bots {
      let b = entry.bot(k)
      do {
        try b.validate()
      } catch {
        throw ImportError("bot \"\(k)\" in the old config is not valid: \(error)")
      }
      cfg.bots[k] = entry
    }
    cfg.settings = old.config.settings
    try await config.replaceAll(cfg)

    // Cursors of imported bots only, tagged with their session.
    var st = StateData()
    for (k, c) in old.state.cursors {
      guard let b = cfg.bots[k] else { continue }
      var cur = c
      if cur.sessionId == nil { cur.sessionId = b.sessionId }
      guard cur.sessionId == b.sessionId else { continue }
      st.cursors[k] = cur
    }
    try await state.replaceAll(st)

    // Tokens (T2).
    let sessions = cfg.bots.mapValues(\.sessionId)
    let recs = old.tokens.compactMap { t -> TokenRecord? in
      let id = t["id"] as? String ?? ""
      return migrateTypeScriptToken(t, sessionOf: { sessions[$0] }, now: now, bindSessionless: keep.contains(id))
    }
    try await tokens.importRecords(recs)

    // The key the old gateway used, once (§20.4).
    let creds = Credentials(keyFile: home.apiKey)
    var copied = false
    if let k = old.key, try creds.saveIfAbsent(key: k) {
      before.append((home.apiKey, nil))
      copied = true
    }

    // Mark the old folder as moved; from now on the TypeScript CLI refuses to run on it.
    struct Marker: Encodable { let movedTo: String; let at: String }
    try FileUtil.writeJSON(marker, Marker(movedTo: home.root.path, at: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: now / 1000))))
    done = true

    let usable = recs.filter { $0.state != .retired }.count
    return Report(bots: cfg.bots.count, cursors: st.cursors.count, usable: usable, retired: recs.count - usable, keyCopied: copied)
  }
}

extension ConfigStore {
  /// Import only: write a whole config (the caller holds the config lock and checked it is empty).
  func replaceAll(_ d: ConfigData) throws {
    data = d
    try save()
  }
}

extension StateStore {
  func replaceAll(_ d: StateData) async throws {
    let lock = try await FileLock.acquire(for: file)
    defer { lock.release() }
    data = d
    try FileUtil.writeJSON(file, data)
    fingerprint = FileUtil.fingerprint(file)
  }
}
