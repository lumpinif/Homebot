// The gateway host: everything `homebot start` and the app run while serving Siri. It takes the
// owner lock (one gateway per support directory, A5), loads the stores, resolves the credential
// per bot turn (with its generation, §20.4), serves the voice API on the LAN, owns the activity
// database and the control socket, keeps the Mac awake (§20.3), and removes expired Shortcut
// files while it runs (TypeScript: the cleanup interval in `start`).
import Foundation
import HomebotCore

public struct GatewayOptions: Sendable {
  public var home: Home
  /// The user's home directory, for the BDK login file (tests pass a temporary one).
  public var userHome: URL
  /// Overrides of the stored settings (CLI flags); nil: settings.
  public var port: Int?
  public var bind: String?
  /// The Grok Bot API base. Only Cursor's API, or a loopback URL for tests and smoke runs.
  public var bdkBaseURL: String
  /// Tests: an in-process transport (the fake Grok Bot API).
  public var transport: HTTPTransport?
  public var probeWait: Bool
  public var probeUnitMs: Int
  public var lab: Bool
  public var labUnit: Double
  public var cleanupMs: Int
  public var keepAwake: Bool
  public var controlSocket: Bool
  public var traceIdle: AskService.TraceIdle
  public var log: LogFn?

  public init(home: Home, userHome: URL = FileManager.default.homeDirectoryForCurrentUser, port: Int? = nil, bind: String? = nil, bdkBaseURL: String = HTTPBdkClient.defaultBaseURL, transport: HTTPTransport? = nil, probeWait: Bool = false, probeUnitMs: Int = 1000, lab: Bool = false, labUnit: Double = 1, cleanupMs: Int = 10 * 60_000, keepAwake: Bool = true, controlSocket: Bool = true, traceIdle: AskService.TraceIdle = AskService.TraceIdle(maxMs: 30_000, everyMs: 1000), log: LogFn? = nil) {
    self.home = home
    self.userHome = userHome
    self.port = port
    self.bind = bind
    self.bdkBaseURL = bdkBaseURL
    self.transport = transport
    self.probeWait = probeWait
    self.probeUnitMs = probeUnitMs
    self.lab = lab
    self.labUnit = labUnit
    self.cleanupMs = cleanupMs
    self.keepAwake = keepAwake
    self.controlSocket = controlSocket
    self.traceIdle = traceIdle
    self.log = log
  }

  /// Cursor's API, or plain HTTP on loopback (the fake Grok Bot API in tests and smoke runs).
  public static func isAllowedBase(_ s: String) -> Bool {
    if s == HTTPBdkClient.defaultBaseURL { return true }
    guard let c = URLComponents(string: s), c.scheme == "http", let h = c.host else { return false }
    return (h == "127.0.0.1" || h == "localhost" || h == "::1") && c.user == nil && c.password == nil && c.query == nil && c.fragment == nil
  }
}

public struct GatewayStatus: Sendable, Codable, Equatable {
  public var running: Bool
  public var port: Int
  public var bind: String
  /// `saved` / `bdk-login`, or nil when there is no credential (never the key, §20.4).
  public var credential: String?
  /// `unchecked` / `ok` / `rejected`.
  public var accepted: String
  public var awake: Bool
  /// False when the activity folder could not be excluded from backups (no text is stored).
  public var textHistory: Bool
  public var bots: Int
  public var lastAt: Double?
  public var lastOutcome: String?
  public var probeWait: Bool
  public var lab: Bool
}

public actor GatewayHost {
  public nonisolated let options: GatewayOptions
  public nonisolated let config: ConfigStore
  public nonisolated let state: StateStore
  public nonisolated let tokens: TokenStore
  public nonisolated let lifecycle: BotLifecycle
  public nonisolated let downloads = Downloads()
  public nonisolated let credentials: Credentials
  public nonisolated let credentialStatus = CredentialStatus()
  public nonisolated let activity: ActivityStore
  let awake = AwakeService()
  let logger: JSONLLogger
  let settingsCache = SettingsCache()

  var owner: OwnerLock?
  var server: HTTPServer?
  var api: VoiceAPI?
  var ask: AskService?
  var control: ControlServer?
  var sweep: Task<Void, Never>?
  /// True while start() runs: a stop() meanwhile waits for it, so ownership is never released
  /// while startup still opens the database or the listener.
  var starting = false
  public private(set) var port = 0
  public private(set) var bind = ""

  public init(_ o: GatewayOptions) {
    options = o
    config = ConfigStore(file: o.home.config)
    state = StateStore(file: o.home.state)
    tokens = TokenStore(file: o.home.tokens, artifactsDir: o.home.shortcuts)
    lifecycle = BotLifecycle(config: config, state: state, tokens: tokens)
    credentials = Credentials(keyFile: o.home.apiKey, userHome: o.userHome)
    activity = ActivityStore(dir: o.home.activity)
    logger = JSONLLogger(dir: o.home.logs)
  }

  public nonisolated var log: LogFn {
    let file = logger.fn
    let extra = options.log
    return { e in
      file(e)
      extra?(e)
    }
  }

  /// Start serving. Throws when another gateway owns this support directory, the address can't
  /// be bound, or the stores can't be read.
  @discardableResult
  public func start() async throws -> GatewayStatus {
    guard server == nil, !starting else { return await status() }
    starting = true
    defer { starting = false }
    guard options.transport != nil || GatewayOptions.isAllowedBase(options.bdkBaseURL) else { throw GatewayError("the Grok Bot API address must be Cursor's API or a loopback test server") }
    try options.home.prepare()
    guard let lock = try OwnerLock.tryAcquire(options.home.gatewayLock) else {
      throw GatewayError("Homebot is already running for this folder (another process owns \(options.home.gatewayLock.lastPathComponent)).")
    }
    owner = lock
    do {
      try await startOwned()
    } catch {
      await teardown()
      throw error
    }
    return await status()
  }

  private func startOwned() async throws {
    let log = self.log
    try await config.load()
    try await state.load()
    try await tokens.load()
    _ = try await tokens.cleanupArtifacts()
    _ = try await tokens.expirePending()
    try await activity.open()
    let settings = await config.settings
    settingsCache.value = settings

    let creds = credentials
    let status = credentialStatus
    let base = options.bdkBaseURL
    let transport = options.transport
    // The credential is resolved once per bot turn, so a key saved or removed meanwhile applies
    // from the next turn without a restart (§20.4).
    let provider: BdkProvider = {
      let c = try? creds.resolve()
      let g = await status.observe(c)
      guard let c else { return nil }
      let client = transport.map { HTTPBdkClient(key: c.key, baseURL: base, transport: $0) } ?? HTTPBdkClient(key: c.key, baseURL: base)
      return BdkSession(client: client, generation: g, key: c.key)
    }
    let ask = AskService(config: config, state: state, bdk: provider, log: log, traceIdle: options.traceIdle, onCredential: { g, ok in await status.record(generation: g, accepted: ok) })
    self.ask = ask
    let cache = settingsCache
    let lifecycle = self.lifecycle
    let conversation = ConversationService(ask: { await ask.ask($0) }, log: log, followupIdleMs: { cache.value.followupIdleMs }, stillGranted: { await lifecycle.stillGranted($0, $1) })
    let config = self.config
    let lab = options.lab ? LabService(file: options.home.lab, log: log, delayUnit: options.labUnit) : nil
    let api = VoiceAPI(VoiceDeps(
      admit: { token, bot, kind, use in try await lifecycle.admit(token, bot: bot, kind: kind, use: use) },
      pin: { token, g in try await lifecycle.admit(token, bot: g.key, session: g.sessionId, kind: .ask, use: true) },
      takeOver: { id, bot, stillThere in try await lifecycle.takeOver(id, bot: bot, while: stillThere) },
      noteAnswer: { [tokens] id, here in try await tokens.noteAnswer(id, here: here) },
      ask: { await ask.ask($0) },
      conversation: conversation,
      settings: {
        try? await config.refresh()
        let s = await config.settings
        cache.value = s
        return s
      },
      bots: {
        try? await config.refresh()
        return await config.bots()
      },
      apiKey: { (try? creds.resolve())?.key },
      activity: activity,
      log: log,
      probeWait: options.probeWait,
      probeUnitMs: options.probeUnitMs,
      downloads: downloads,
      lab: lab))
    self.api = api
    let bind = options.bind ?? settings.bind
    let server = HTTPServer(host: bind)
    port = try await server.start(port: options.port ?? settings.port, api: api)
    self.bind = bind
    self.server = server
    if keepAwake ?? options.keepAwake { awake.hold() }
    if options.controlSocket {
      control = try ControlServer(path: options.home.controlSocket.path) { [weak self] req in
        guard let self else { return Data(#"{"error":"stopped"}"#.utf8) }
        return await self.control(req)
      }
    }
    let tokens = self.tokens
    let every = UInt64(max(options.cleanupMs, 10)) * 1_000_000
    // While the gateway runs, expired artifacts are removed within cleanupMs of their 24 h.
    sweep = Task.detached {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: every)
        if Task.isCancelled { break }
        do {
          let removed = try await tokens.cleanupArtifacts()
          if !removed.isEmpty { log(["event": "artifacts-removed", "count": .int(removed.count)]) }
        } catch {
          log(["event": "artifacts-cleanup-error", "error": .string(Log.errorName(error))])
        }
      }
    }
    let c = try? creds.resolve()
    await credentialStatus.observe(c)
    log(["event": "listening", "port": .int(port), "credential": .string(c?.source.rawValue ?? "none"), "bots": .int(await config.bots().count)])
  }

  public func stop() async {
    while starting { try? await Task.sleep(nanoseconds: 10_000_000) }
    await teardown()
  }

  private func teardown() async {
    sweep?.cancel()
    sweep = nil
    control?.stop()
    control = nil
    await server?.stop()
    server = nil
    await ask?.stop()
    await ask?.flush()
    ask = nil
    await activity.flush()
    await activity.close()
    awake.release()
    owner?.release()
    owner = nil
  }

  public var isRunning: Bool { server != nil }

  /// The app's "Keep this Mac awake" switch: held only while serving, so a stopped gateway never
  /// keeps the Mac up.
  public private(set) var keepAwake: Bool?

  public func setKeepAwake(_ on: Bool) {
    keepAwake = on
    if on && server != nil { awake.hold() } else { awake.release() }
  }

  public func status() async -> GatewayStatus {
    // Read from the activity store, not the voice API's memory: a request answered before a
    // restart is still the last request, and a Clear empties both together.
    let last = server == nil ? nil : (try? await activity.latest()) ?? nil
    return GatewayStatus(
      running: server != nil, port: port, bind: bind,
      credential: await credentialStatus.source?.rawValue, accepted: await credentialStatus.state.rawValue,
      awake: awake.isHeld, textHistory: await activity.textAllowed, bots: await config.bots().count,
      lastAt: last?.at, lastOutcome: last?.outcome, probeWait: options.probeWait, lab: options.lab)
  }

  /// One control request (see Control.swift).
  func control(_ req: Data) async -> Data {
    let obj = (try? JSONSerialization.jsonObject(with: req)) as? [String: Any] ?? [:]
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    func encoded<T: Encodable>(_ v: T) -> Data { (try? enc.encode(v)) ?? Data(#"{"error":"encode"}"#.utf8) }
    switch obj["cmd"] as? String {
    case "status":
      return encoded(await status())
    case "activity":
      let limit = (obj["limit"] as? Int) ?? 50
      do {
        return encoded(["records": try await activity.recent(limit: min(max(limit, 1), 10_000))])
      } catch {
        return Data(#"{"error":"cannot read activity"}"#.utf8)
      }
    case "clear":
      do {
        try await activity.clear()
        log(["event": "activity-cleared"])
        return Data(#"{"ok":true}"#.utf8)
      } catch {
        return Data(#"{"error":"cannot clear activity"}"#.utf8)
      }
    default:
      return Data(#"{"error":"unknown command"}"#.utf8)
    }
  }
}

/// The settings as last read, for code that can't wait on the config actor.
final class SettingsCache: @unchecked Sendable {
  private let lock = NSLock()
  private var v = Settings()
  var value: Settings {
    get { lock.withLock { v } }
    set { lock.withLock { v = newValue } }
  }
}
