// The `homebot` command for agents and power users (DESIGN §20.2): the TypeScript CLI's commands
// where they still make sense, plus `status`, `log`, `account` and `import`. It works on the same
// stores as the app under the same locks. Activity is read and cleared through the running
// gateway (A5); `start` runs the gateway headless. No command prints a token or key. Ported from
// src/cli.ts.
import ArgumentParser
import Foundation
import HomebotCore
import HomebotGateway

/// Everything a command touches outside its arguments; tests replace all of it.
public struct CLIIO: Sendable {
  public var out: @Sendable (String) -> Void
  public var err: @Sendable (String) -> Void
  /// The user's home directory (the BDK login file and the default TypeScript folder).
  public var userHome: URL
  /// The support directory when `--home` is not given; nil: ~/Library/Application Support/Homebot.
  public var defaultHome: URL?
  /// Tests: the fake Grok Bot API as an in-process transport.
  public var transport: HTTPTransport?
  public var bdkBaseURL: String
  public var readStdin: @Sendable () -> String?
  public var hostName: @Sendable () -> String
  /// nil: Apple's signing service through `shortcuts sign`.
  public var sign: SignFn?
  public var reveal: @Sendable (URL) async -> Void
  /// Tests: called once `start` is serving, instead of waiting for SIGINT/SIGTERM.
  public var onStarted: (@Sendable (GatewayHost) async -> Void)?
  public var probeUnitMs: Int
  public var labUnit: Double
  public var cleanupMs: Int
  public var keepAwake: Bool
  /// Tests: replaces the check for a running TypeScript gateway during import.
  public var isListening: @Sendable (Int) -> Bool

  public init(
    out: @escaping @Sendable (String) -> Void = { print($0) },
    err: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
    userHome: URL = FileManager.default.homeDirectoryForCurrentUser, defaultHome: URL? = nil, transport: HTTPTransport? = nil,
    bdkBaseURL: String = HTTPBdkClient.defaultBaseURL,
    readStdin: @escaping @Sendable () -> String? = { String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) },
    hostName: @escaping @Sendable () -> String = { ShortcutMaker.localHostName() }, sign: SignFn? = nil,
    reveal: @escaping @Sendable (URL) async -> Void = { u in try? await Signer.runProcess("/usr/bin/open", ["-R", u.path]) },
    onStarted: (@Sendable (GatewayHost) async -> Void)? = nil, probeUnitMs: Int = 1000, labUnit: Double = 1, cleanupMs: Int = 10 * 60_000, keepAwake: Bool = true,
    isListening: @escaping @Sendable (Int) -> Bool = { TSImport.listening($0) }
  ) {
    self.out = out
    self.err = err
    self.userHome = userHome
    self.defaultHome = defaultHome
    self.transport = transport
    self.bdkBaseURL = bdkBaseURL
    self.readStdin = readStdin
    self.hostName = hostName
    self.sign = sign
    self.reveal = reveal
    self.onStarted = onStarted
    self.probeUnitMs = probeUnitMs
    self.labUnit = labUnit
    self.cleanupMs = cleanupMs
    self.keepAwake = keepAwake
    self.isListening = isListening
  }
}

enum CLI {
  @TaskLocal static var io = CLIIO()
  static func out(_ s: String) { io.out(s) }
}

/// A failure to report as `homebot: <message>` (exit 1).
struct UserError: Error, CustomStringConvertible {
  let description: String
  init(_ d: String) { description = d }
}

public enum HomebotCLI {
  /// Run one command; returns the exit code (0 ok, 1 failed, 2 usage).
  public static func run(_ argv: [String], io: CLIIO = CLIIO()) async -> Int32 {
    await CLI.$io.withValue(io) {
      do {
        var cmd = try Root.parseAsRoot(argv)
        if var a = cmd as? AsyncParsableCommand {
          try await a.run()
        } else {
          try cmd.run()
        }
        return 0
      } catch let e as UserError {
        io.err("homebot: \(e.description)")
        return 1
      } catch let e as ExitCode {
        return e.rawValue
      } catch {
        if let ours = describeOwn(error) {
          io.err("homebot: \(ours)")
          return 1
        }
        let code = Root.exitCode(for: error)
        // A usage error quotes the arguments it could not use. Under `account` that could be a key
        // typed on the command line: say only what to do instead.
        if code != .success, argv.first == "account" {
          io.err("homebot: unexpected arguments for `homebot \(argv.prefix(2).joined(separator: " "))` (not shown). The key is read from standard input, never from an argument, e.g. pbpaste | homebot account set-key")
          return 2
        }
        let msg = Root.fullMessage(for: error)
        if code == .success {
          io.out(msg)
          return 0
        }
        io.err(msg)
        return 2
      }
    }
  }

  /// Errors from Homebot's own code (not argument parsing), as text without secrets.
  static func describeOwn(_ e: Error) -> String? {
    if let b = e as? BdkError { return b.kind == .auth ? "Grok Bot rejected the credentials (\(b.status.map(String.init) ?? "auth"))" : b.message }
    switch e {
    case let x as StoreError: return x.description
    case let x as TokenError: return x.description
    case let x as FileUtil.FileError: return x.description
    case let x as GatewayError: return x.description
    case let x as TSImport.ImportError: return x.description
    case let x as Reset.ResetError: return x.description
    case let x as ShortcutMaker.MakeError: return x.description
    case let x as Profile.ProfileError: return x.description
    case let x as SignError: return x.description
    case let x as BotSetupError: return x.description
    case let x as ControlError: return x.description
    case let x as ActivityError: return x.description
    case is HistoryTooLongError: return String(describing: e)
    default: return nil
    }
  }
}

struct Global: ParsableArguments {
  @Option(name: .long, help: "The support folder (default: ~/Library/Application Support/Homebot).")
  var home: String?
  /// Test servers only: the fake Grok Bot API on loopback (Cursor's API is the default).
  @Option(name: .customLong("bdk-base-url"), help: .hidden)
  var bdkBaseURL: String?
}

/// The stores of one command, opened as the TypeScript CLI did: every run prepares the folder and
/// enforces the 24 h Shortcut-file lifetime.
struct Ctx {
  let home: Home
  let config: ConfigStore
  let state: StateStore
  let tokens: TokenStore
  let lifecycle: BotLifecycle
  let credentials: Credentials
  let bdkBaseURL: String

  static func open(_ g: Global) async throws -> Ctx {
    let io = CLI.io
    let base = g.bdkBaseURL ?? io.bdkBaseURL
    guard io.transport != nil || GatewayOptions.isAllowedBase(base) else { throw UserError("--bdk-base-url must be a loopback http URL (test servers only)") }
    let root = g.home.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) } ?? io.defaultHome
    let home = try Home(root: root)
    try home.prepare()
    let config = try await ConfigStore(file: home.config).load()
    let state = try await StateStore(file: home.state).load()
    let tokens = try await TokenStore(file: home.tokens, artifactsDir: home.shortcuts).load()
    _ = try await tokens.cleanupArtifacts()
    return Ctx(home: home, config: config, state: state, tokens: tokens, lifecycle: BotLifecycle(config: config, state: state, tokens: tokens), credentials: Credentials(keyFile: home.apiKey, userHome: io.userHome), bdkBaseURL: base)
  }

  func client() throws -> BdkClient {
    guard let c = try credentials.resolve() else {
      throw UserError("No Grok Bot credentials found. Save a Cursor API key with `homebot account set-key` (it reads the key from standard input).")
    }
    let io = CLI.io
    return io.transport.map { HTTPBdkClient(key: c.key, baseURL: bdkBaseURL, transport: $0) } ?? HTTPBdkClient(key: c.key, baseURL: bdkBaseURL)
  }

  /// The running gateway's answer to a control request, or nil when none runs.
  func control(_ req: [String: Any]) throws -> [String: Any]? {
    let data: Data
    do {
      data = try ControlClient.call(path: home.controlSocket.path, try JSONSerialization.data(withJSONObject: req))
    } catch ControlError.noOwner {
      return nil
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
  }
}

func siriOptions() -> String { Lang.allCases.map(\.info.siri).joined(separator: ", ") }

struct Root: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "homebot",
    abstract: "Homebot: ask your Grok Bots from Siri on HomePod.",
    discussion: "Only use the gateway on a trusted home network. Never port-forward its port.",
    subcommands: [Start.self, Status.self, Doctor.self, BotCmd.self, TokenCmd.self, ShortcutCmd.self, LogCmd.self, AccountCmd.self, Import.self, ResetCmd.self, LabCmd.self]
  )
}

// MARK: start / status / doctor

struct Start: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Run the voice gateway in this terminal (headless; the app runs the same gateway).")
  @OptionGroup var g: Global
  @Option(help: "Listen on this port instead of the stored setting.") var port: Int?
  @Option(help: "Listen on this address instead of the stored setting.") var bind: String?
  @Flag(name: .customLong("probe-wait"), help: "Also serve the Siri wait-limit probe (device session only).") var probeWait = false
  @Flag(help: "Also serve the lab Shortcut's experiments (device session only; never contacts a bot).") var lab = false
  @Flag(name: .customLong("no-keep-awake"), help: "Don't keep the Mac awake while serving.") var noKeepAwake = false

  func run() async throws {
    let io = CLI.io
    let ctx = try await Ctx.open(g)
    let base = ctx.bdkBaseURL
    let host = GatewayHost(GatewayOptions(
      home: ctx.home, userHome: io.userHome, port: port, bind: bind, bdkBaseURL: base, transport: io.transport,
      probeWait: probeWait, probeUnitMs: io.probeUnitMs, lab: lab, labUnit: io.labUnit, cleanupMs: io.cleanupMs,
      keepAwake: io.keepAwake && !noKeepAwake))
    let st = try await host.start()
    let bots = await ctx.config.bots().map(\.key)
    CLI.out("Homebot voice gateway listening on \(st.bind):\(st.port) (credentials: \(st.credential ?? "none yet"), bots: \(bots.isEmpty ? "none" : bots.joined(separator: ", ")))")
    if st.credential == nil { CLI.out("No Grok Bot credentials yet: save a Cursor API key with `homebot account set-key` (it reads the key from standard input).") }
    CLI.out("Only use it on a trusted home network. Never port-forward this port.")
    if st.awake { CLI.out("This Mac stays awake while the gateway runs (idle sleep only; closing the lid still sleeps it).") }
    if probeWait { CLI.out("Wait-limit probe enabled at /v1/probe-wait (restart without --probe-wait when done).") }
    if lab { CLI.out("Lab enabled at /v1/lab, experiment \(Lab.readState(ctx.home.lab).scenario.rawValue) (homebot lab use <E1, E1b, E2..E7> to change; restart without --lab when done).") }
    if let started = io.onStarted {
      await started(host)
      return
    }
    await waitForSignal()
    CLI.out("Stopping the gateway.")
    await host.stop()
  }

  /// Block until SIGINT or SIGTERM.
  func waitForSignal() async {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let q = DispatchQueue(label: "homebot.signals")
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      let once = OnceFlag()
      var sources: [DispatchSourceSignal] = []
      for s in [SIGINT, SIGTERM] {
        let src = DispatchSource.makeSignalSource(signal: s, queue: q)
        src.setEventHandler {
          if once.set() { c.resume() }
        }
        src.resume()
        sources.append(src)
      }
      Retainer.keep(sources)
    }
  }
}

final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false
  func set() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

enum Retainer {
  nonisolated(unsafe) static var kept: [AnyObject] = []
  static func keep(_ objs: [AnyObject]) { kept.append(contentsOf: objs) }
}

struct Status: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Show the running gateway's status (exit 1 when none runs).")
  @OptionGroup var g: Global
  @Flag(help: "Print JSON.") var json = false

  func run() async throws {
    let ctx = try await Ctx.open(g)
    guard let st = try ctx.control(["cmd": "status"]) else {
      CLI.out(json ? #"{"running":false}"# : "Homebot gateway: not running")
      throw ExitCode(1)
    }
    if json {
      CLI.out(String(decoding: try JSONSerialization.data(withJSONObject: st, options: [.sortedKeys]), as: UTF8.self))
      return
    }
    CLI.out("Homebot gateway: running on \(st["bind"] as? String ?? "?"):\(st["port"] as? Int ?? 0)")
    CLI.out("Credentials: \(st["credential"] as? String ?? "none") (Grok Bot: \(st["accepted"] as? String ?? "unchecked"))")
    CLI.out("Keeps this Mac awake: \((st["awake"] as? Bool) == true ? "yes" : "no")")
    CLI.out("Text history: \((st["textHistory"] as? Bool) == true ? "on (excluded from Time Machine backups)" : "off (the activity folder could not be excluded from backups)")")
    CLI.out("Bots: \(st["bots"] as? Int ?? 0)")
    if let at = st["lastAt"] as? Double {
      CLI.out("Last request: \(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: at / 1000))) \(st["lastOutcome"] as? String ?? "")")
    } else {
      CLI.out("Last request: none since start")
    }
  }
}

struct Doctor: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Check the setup (read-only calls to Grok Bot).")
  @OptionGroup var g: Global

  func run() async throws {
    let ctx = try await Ctx.open(g)
    CLI.out("Homebot folder: \(ctx.home.root.path)")
    let c = try ctx.credentials.resolve()
    CLI.out("Credentials: \(c?.source.rawValue ?? "MISSING")")
    switch ctx.credentials.loginStatus {
    case .otherBackend: CLI.out("Note: a Grok Bot login was found on this Mac, but for another server; it is not used.")
    case .unreadable: CLI.out("Note: a Grok Bot login file was found on this Mac but can't be read; it is not used.")
    default: break
    }
    let running = try ctx.control(["cmd": "status"])
    CLI.out("Gateway: \(running.map { "running on port \($0["port"] as? Int ?? 0)" } ?? "not running")")
    var ok = c != nil
    let bots = await ctx.config.bots()
    if bots.isEmpty { CLI.out("Bots: none configured (use `homebot bot add-name`)") }
    for b in bots {
      guard let cur = await ctx.state.cursor(b.key) else {
        CLI.out("Bot \(b.key): no cursor; add it again with `homebot bot add-id \(b.sessionId) --key \(b.key) --name ...`")
        ok = false
        continue
      }
      guard c != nil else { continue }
      do {
        let bdk = try ctx.client()
        let r = try await syncToEnd(cursor: cur.cursor, maxSeq: cur.maxSeq, maxPages: 50) { try await bdk.getEntries(sessionId: b.sessionId, afterUpdatedSeq: $0) }
        try await ctx.state.setCursor(b.key, cursor: r.cursor, maxSeq: r.maxSeq, sessionId: b.sessionId)
        CLI.out("Bot \(b.key) (\(b.name)): readable, \(isBusy(r.turn) ? "busy" : "idle"), \(r.entries.count) new entries since last sync")
      } catch {
        CLI.out("Bot \(b.key): \(HomebotCLI.describeOwn(error) ?? "check failed")")
        ok = false
      }
    }
    let usable = await ctx.tokens.list().filter { $0.state != .retired }.count
    CLI.out("Tokens: \(usable) usable")
    if !ok { throw ExitCode(1) }
  }
}

// MARK: bot

struct BotCmd: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "bot", abstract: "Add, list, rename and remove bots.", subcommands: [AddName.self, AddId.self, List.self, Alias.self, Remove.self])

  struct AddName: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add-name", abstract: "Add a bot by its exact name (a typo creates an empty bot, which is detected and not added).")
    @OptionGroup var g: Global
    @Argument var name: String
    @Option var key: String
    @Option(help: "The exact name again.") var confirm: String?
    @Flag(name: .customLong("no-strict")) var noStrict = false

    func run() async throws {
      let ctx = try await Ctx.open(g)
      // Get-or-create: a typo creates a new empty bot in the account, so the exact name must be
      // typed twice (DECISIONS item 13).
      guard confirm == name else {
        throw UserError("Grok Bot creates a new empty bot if no bot is named exactly \"\(name)\". Check the spelling, then repeat it with --confirm \"\(name)\".")
      }
      try await ctx.config.checkBot(Bot(key: key, name: name, sessionId: "0", strictEcho: true))
      let bdk = try ctx.client()
      let found = try await Bots.resolveByName(bdk, name: name)
      if found.justCreated {
        throw UserError("No bot was named exactly \"\(name)\", so Grok Bot just created an empty one (session \(found.sessionId)). It was not added. Check the exact name, and delete the empty bot in the Grok Bot app.")
      }
      let bot = Bot(key: key, name: name, sessionId: found.sessionId, strictEcho: !noStrict)
      try await ctx.config.checkBot(bot)
      let r = try await Bots.coldSync(bdk, sessionId: found.sessionId)
      try await ctx.lifecycle.add(bot, cursor: r.cursor, maxSeq: r.maxSeq)
      CLI.out("Added \(key) -> \"\(name)\" (session \(found.sessionId)): readable, \(r.entryCount) entries, \(isBusy(r.turn) ? "busy" : "idle").")
    }
  }

  struct AddId: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add-id", abstract: "Add a bot by numeric session id (advanced; read-only check).")
    @OptionGroup var g: Global
    @Argument var sessionId: String
    @Option var key: String
    @Option var name: String
    @Flag(name: .customLong("no-strict")) var noStrict = false
    @Flag(help: "Print the latest bot message (true latest, via full sync).") var preview = false

    func run() async throws {
      let ctx = try await Ctx.open(g)
      let bot = Bot(key: key, name: name, sessionId: sessionId, strictEcho: !noStrict)
      try await ctx.config.checkBot(bot) // format and identity conflicts, before any network call
      let bdk = try ctx.client()
      let r = try await Bots.coldSync(bdk, sessionId: sessionId)
      try await ctx.lifecycle.add(bot, cursor: r.cursor, maxSeq: r.maxSeq)
      CLI.out("Added \(key) -> session \(sessionId): readable, \(r.entryCount) entries in \(r.pages) page(s), \(isBusy(r.turn) ? "busy" : "idle").")
      if preview {
        // Bot text is never printed as is: protocol fragments and the key in use are removed (A1).
        let shown = r.latestBotText.map { ProtocolFilter.clean($0, secrets: [(try? ctx.credentials.resolve())?.key].compactMap { $0 }) }
        CLI.out("Latest bot message (true latest, via full sync): \(shown ?? "(none)")")
      }
    }
  }

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List bots: key, name, session, strict echo, synced.")
    @OptionGroup var g: Global

    func run() async throws {
      let ctx = try await Ctx.open(g)
      for b in await ctx.config.bots() {
        let synced = await ctx.state.cursor(b.key) != nil
        CLI.out("\(b.key)\t\(b.name)\t\(b.sessionId)\tstrict=\(b.strictEcho)\tsynced=\(synced ? "yes" : "no")\(b.aliases.isEmpty ? "" : "\taliases=\(b.aliases.joined(separator: ","))")")
      }
    }
  }

  struct Alias: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Set the other names Siri may hear for a bot in the one-phrase Shortcut; the first is the name spoken in its menu.")
    @OptionGroup var g: Global
    @Argument var key: String
    @Argument(help: "The names, in order (none: clear them).") var names: [String] = []

    func run() async throws {
      let ctx = try await Ctx.open(g)
      guard try await ctx.lifecycle.setAliases(key, names) else { throw UserError("Unknown bot: \(key)") }
      CLI.out(names.isEmpty ? "\(key) has no other names now." : "\(key) is also called: \(names.joined(separator: ", ")).")
      await EntryNotes.warnAmbiguous(ctx)
    }
  }

  struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove a bot (its grant leaves every Shortcut token; tokens left empty are retired).")
    @OptionGroup var g: Global
    @Argument var key: String

    func run() async throws {
      let ctx = try await Ctx.open(g)
      guard let r = try await ctx.lifecycle.remove(key) else { throw UserError("Unknown bot: \(key)") }
      CLI.out("Removed \(key); \(r.retired.count) Shortcut token(s) retired\(r.narrowed.isEmpty ? "" : ", \(r.narrowed.count) narrowed").")
    }
  }
}

// MARK: token

struct TokenCmd: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "token", abstract: "Issue, list, edit and revoke Shortcut tokens.", subcommands: [Issue.self, List.self, Bots.self, Revoke.self])

  struct Issue: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Issue a client token; writes it to a 0600 file (never printed).")
    @OptionGroup var g: Global
    @Argument var botKey: String
    @Option(name: .customLong("siri-lang")) var siriLang = Langs.defaultSiriLang
    @Option var label: String?
    @Option var replaces: String?
    @Flag(name: .customLong("curl-header"), help: "Write it as \"X-Homebot-Token: ...\" for curl -H @file.") var curlHeader = false

    func run() async throws {
      let ctx = try await Ctx.open(g)
      guard let bot = await ctx.config.bot(botKey) else { throw UserError("Unknown bot: \(botKey)") }
      guard Langs.isSiriLang(siriLang) else { throw UserError("--siri-lang must be one of: \(siriOptions())") }
      let tokens = ctx.tokens
      let (label, replaces, siriLang) = (self.label, self.replaces, self.siriLang)
      let (id, token) = try await ctx.lifecycle.issueFor([bot]) { b in
        try await tokens.issue(bots: b.map { BotGrant(key: $0.key, sessionId: $0.sessionId) }, label: label ?? b[0].name, replaces: replaces, siriLang: siriLang, mode: .single)
      }
      // --curl-header: a ready header line for `curl -H @file`, so the token never appears on a
      // command line, in shell history or in `ps`.
      let file = try tokens.artifactPath(id, ext: curlHeader ? "header" : "token")
      try FileUtil.writePrivateFile(file, curlHeader ? "X-Homebot-Token: \(token)\n" : token + "\n")
      CLI.out("Issued pending token \(id) for \(bot.key). Secret written to \(file.path) (mode 0600). It becomes active once a request with it is answered; the file is deleted on its first use, on revoke/expiry, or once it is 24 h old (by the running gateway, or by the next homebot command if none is running).")
    }
  }

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List tokens: id, bots, state, label, Siri language, created.")
    @OptionGroup var g: Global

    func run() async throws {
      let ctx = try await Ctx.open(g)
      let iso = ISO8601DateFormatter()
      iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      for t in await ctx.tokens.list() {
        CLI.out("\(t.id)\t\(t.bots.map(\.key).joined(separator: ","))\t\(t.state.rawValue)\t\(t.label)\t\(t.siriLang ?? Langs.defaultSiriLang)\t\(iso.string(from: Date(timeIntervalSince1970: t.createdAt / 1000)))")
      }
    }
  }

  struct Bots: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Change which bots a one-phrase Shortcut answers for (no new Shortcut needed; DESIGN §20.5 T4).")
    @OptionGroup var g: Global
    @Argument var tokenId: String
    @Argument(help: "Bot keys, comma-separated, in menu order.") var bots: String

    func run() async throws {
      let ctx = try await Ctx.open(g)
      let keys = EntryNotes.keys(bots)
      var list: [Bot] = []
      for k in keys {
        guard let b = await ctx.config.bot(k) else { throw UserError("Unknown bot: \(k)") }
        list.append(b)
      }
      guard !list.isEmpty else { throw UserError("Name at least one bot. To stop a Shortcut, revoke it.") }
      try await ctx.lifecycle.setBots(tokenId, list)
      CLI.out("Token \(tokenId) now answers for: \(keys.joined(separator: ", ")).")
      await EntryNotes.warnAmbiguous(ctx)
    }
  }

  struct Revoke: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Revoke a token (its Shortcut stops working at once).")
    @OptionGroup var g: Global
    @Argument var tokenId: String

    func run() async throws {
      let ctx = try await Ctx.open(g)
      guard try await ctx.tokens.revoke(tokenId) else { throw UserError("Unknown token id: \(tokenId)") }
      CLI.out("Revoked \(tokenId).")
    }
  }
}

// MARK: shortcut

struct ShortcutCmd: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "shortcut", abstract: "Build Shortcut files.", subcommands: [Build.self])

  struct Build: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Build a Shortcut file (token inside; private, short-lived).")
    @OptionGroup var g: Global
    @Argument(help: "The bot (not with --entry).") var botKey: String?
    @Option(name: .customLong("siri-lang")) var siriLang: String?
    @Option(name: .customLong("phone-lang")) var phoneLang: String?
    @Option(help: "The Siri phrase.") var name: String?
    @Option(help: "The gateway URL the Shortcut calls (default: http://<this Mac>.local:<port>).") var url: String?
    @Option var replaces: String?
    @Flag var probe = false
    @Flag var lab = false
    @Flag(help: "Siri keeps listening after each answer (experimental, DESIGN §18).") var conversation = false
    @Flag(help: "One phrase for several bots: Siri asks which one (DESIGN §20.5; not yet tried on a HomePod).") var entry = false
    @Option(help: "With --entry: bot keys, comma-separated, in menu order (default: every bot, at most 9).") var bots: String?
    @Flag(help: "Send the Shortcut to Apple's signing service (records that consent).") var sign = false
    @Flag(help: "Show the signed file in Finder.") var reveal = false

    func run() async throws {
      let io = CLI.io
      let ctx = try await Ctx.open(g)
      let test = probe || lab
      if [probe, lab, conversation, entry].filter({ $0 }).count > 1 { throw UserError("Use only one of --probe, --lab, --conversation and --entry.") }
      if bots != nil && !entry { throw UserError("--bots goes with --entry.") }
      var chosen: [Bot] = []
      if entry {
        if botKey != nil { throw UserError("With --entry, name the bots with --bots a,b (not as an argument).") }
        if let bots {
          for k in EntryNotes.keys(bots) {
            guard let b = await ctx.config.bot(k) else { throw UserError("Unknown bot: \(k)") }
            chosen.append(b)
          }
        } else {
          chosen = await ctx.config.bots()
          if chosen.count > TokenStore.maxBots { throw UserError("You have \(chosen.count) bots; one Shortcut answers for at most \(TokenStore.maxBots). Choose them with --bots a,b.") }
        }
        if chosen.isEmpty { throw UserError("Add a bot first.") }
      } else {
        guard let botKey else { throw UserError("Name the bot, or use --entry for one phrase for several bots.") }
        guard let bot = await ctx.config.bot(botKey) else { throw UserError("Unknown bot: \(botKey)") }
        chosen = [bot]
      }
      let bot = chosen[0]
      let s = await ctx.config.settings
      let list = await ctx.tokens.list()
      // Repeated spaces in a phrase are one space (TypeScript's --name handling).
      let phrase = name.map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }
      let lang = siriLang ?? s.siriLang ?? Langs.defaultSiriLang
      let phone = phoneLang ?? s.phoneLang ?? Langs.defaultPhoneLang.rawValue
      let keep = Profile.keptPhrase(replaces.flatMap { r in list.first { $0.id == r } }, siriLang: lang)
      let chain = TokenStore.takeoverChain(from: replaces) { r in list.first { $0.id == r && $0.state == .pending && $0.usedAt == nil }?.replaces }
      // Copies for another Apple Account never take a phrase from this one (S26).
      let other = replaces.flatMap { r in list.first { $0.id == r }?.otherAccount } == true
      let taken = other ? [] : Profile.takenPhrases(list.filter { $0.otherAccount != true }.map { ($0.id, $0.label, $0.state) }, replaces: replaces, chain: chain)
      let profile = entry
        ? try Profile.entry(siriLang: lang, phoneLang: phone, name: phrase, keep: keep, taken: taken)
        : try Profile.make(botName: bot.name, siriLang: lang, phoneLang: phone, name: phrase, keep: keep, taken: taken)
      let blocking = test ? [] : profile.problems.filter(\.blocking)
      if !blocking.isEmpty {
        let others = profile.alternatives.isEmpty ? "" : " Phrases you can use: \(profile.alternatives.map { "\"\($0)\"" }.joined(separator: ", "))."
        throw UserError(blocking.map(\.message).joined(separator: " ") + others)
      }
      if !test { for p in profile.problems { CLI.out("Note: \(p.message)") } }
      let baseUrl = url ?? "http://\(io.hostName()).local:\(s.port)"
      guard let host = URLComponents(string: baseUrl).flatMap({ c in c.host.map { h in c.port.map { "\(h):\($0)" } ?? h } }) else { throw UserError("gateway URL must be http(s)://host:port, got \"\(baseUrl)\"") }
      // --sign is the user's consent to Apple's signing service (DESIGN §7.5). Recorded only once
      // the build passed its checks, so a refused command leaves no consent behind.
      if sign && s.appleSigning != true {
        var p = SettingsPatch()
        p.appleSigning = true
        try await ctx.config.putSettings(p)
      }
      let out = io.out
      let signer: SignFn? = sign ? (io.sign ?? { input, output in
        _ = try await Signer.sign(input: input, output: output, onAttempt: { n, mode in out("Signing (attempt \(n), mode \(mode.rawValue))…") })
      }) : nil
      let kind: ShortcutKind = probe ? .probe : lab ? .lab : conversation ? .conversation : entry ? .entry : .ask
      let r = try await ShortcutMaker.make(tokens: ctx.tokens, lifecycle: ctx.lifecycle, bots: chosen, profile: profile, baseUrl: baseUrl, kind: kind, replaces: replaces, sign: signer)
      CLI.out("Built \"\(r.name)\" for \(entry ? "bots \(chosen.map(\.key).joined(separator: ", "))" : "bot \(bot.key)") (Siri \(profile.siriLang), gateway \(baseUrl)).")
      if entry {
        let reply = Langs.replyLang(profile.siriLang)
        let first = EntryPreview.lines(phrase: r.name, bots: chosen.map(EntryChoice.init), siriLang: profile.siriLang)
        CLI.out("What Siri will say: \(first.map { "\($0.user ? "You" : "Siri"): \($0.text)" }.joined(separator: " / "))")
        for n in Chooser.ambiguousNames(chosen.map(EntryChoice.init), reply) { CLI.out("Note: \"\(n)\" can only be chosen by its number (it sounds like another bot, a number or a yes/no word).") }
        CLI.out("Note: this one-phrase Shortcut has not been tried on a HomePod yet; keep your per-bot Shortcuts until it has.")
      }
      if !test && r.name != profile.name { CLI.out("Note: the name was changed from \"\(profile.name)\" to \"\(r.name)\" because iOS uses the file name, which can't contain / \\ : or start with a dot.") }
      CLI.out("File: \(r.file.path) (\(r.signed ? "signed" : "UNSIGNED: iOS will not import it until it is signed"); private; deleted on first use, or once 24 h old by the running gateway or the next homebot command).")
      CLI.out("Token \(r.tokenId) is pending; it becomes active once the Shortcut's first question is answered\(replaces.map { ", and then retires \($0), which keeps working until then" } ?? "").")
      if r.signed && reveal { await io.reveal(r.file) }
      CLI.out("")
      for (i, step) in profile.steps(host: host, name: r.name).enumerated() { CLI.out("\(i + 1). \(step)") }
    }
  }
}

/// Shared by the commands that build or edit a one-phrase Shortcut.
enum EntryNotes {
  static func keys(_ list: String) -> [String] {
    list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  /// Names in a one-phrase Shortcut's menu that can be chosen by number only (DESIGN §20.5 rule 2).
  static func warnAmbiguous(_ ctx: Ctx) async {
    let bots = Dictionary((await ctx.config.bots()).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    for t in await ctx.tokens.list() where t.state != .retired && t.mode == .entry {
      let items = t.bots.compactMap { bots[$0.key].map(EntryChoice.init) }
      for n in Chooser.ambiguousNames(items, Langs.replyLang(t.siriLang ?? Langs.defaultSiriLang)) {
        CLI.out("Note: in \"\(t.label)\", \"\(n)\" can only be chosen by its number (it sounds like another bot, a number or a yes/no word).")
      }
    }
  }
}

// MARK: log (activity)

struct LogCmd: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "log", abstract: "Show or clear the activity history (questions as spoken; stays on this Mac).", subcommands: [Show.self, Clear.self], defaultSubcommand: Show.self)

  /// Run `fn` on the activity store when no gateway owns it (A5): this process takes the owner
  /// lock for the duration, so a gateway can't open the database meanwhile.
  static func direct<T: Sendable>(_ ctx: Ctx, _ fn: (ActivityStore) async throws -> T) async throws -> T {
    guard let lock = try OwnerLock.tryAcquire(ctx.home.gatewayLock) else { throw UserError("the running gateway did not answer; try again") }
    let store = ActivityStore(dir: ctx.home.activity)
    do {
      try await store.open()
      let r = try await fn(store)
      await store.close()
      lock.release()
      return r
    } catch {
      // The database is closed before the lock is released, also on failure (A5).
      await store.close()
      lock.release()
      throw error
    }
  }

  struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Print the latest activity records, newest first.")
    @OptionGroup var g: Global
    @Option var limit = 50
    @Flag(help: "One JSON object per line.") var json = false

    func run() async throws {
      let ctx = try await Ctx.open(g)
      let records: [ActivityRecord]
      if let r = try ctx.control(["cmd": "activity", "limit": limit]) {
        guard let list = r["records"] else { throw UserError(r["error"] as? String ?? "the gateway could not read activity") }
        records = try JSONDecoder().decode([ActivityRecord].self, from: JSONSerialization.data(withJSONObject: list))
      } else {
        let n = limit
        records = try await LogCmd.direct(ctx) { try await $0.recent(limit: n) }
      }
      let enc = JSONEncoder()
      enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let iso = ISO8601DateFormatter()
      if records.isEmpty && !json { CLI.out("No activity yet.") }
      for r in records {
        if json {
          CLI.out(String(decoding: try enc.encode(r), as: UTF8.self))
          continue
        }
        let time = iso.string(from: Date(timeIntervalSince1970: r.at / 1000))
        let bot = r.botName ?? r.botKey ?? "-"
        let q = r.question.map { "\"\($0)\"" } ?? "-"
        let s = r.spoken.map { "\"\($0)\"" } ?? "-"
        CLI.out("\(time)\t\(r.outcome)\t\(bot)\t\(r.label)\t\(q) -> \(s)")
      }
    }
  }

  struct Clear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete every activity record (the diagnostic log is kept).")
    @OptionGroup var g: Global
    @Flag(help: "Confirm.") var yes = false

    func run() async throws {
      guard yes else { throw UserError("This deletes every activity record, questions included. Repeat with --yes to confirm.") }
      let ctx = try await Ctx.open(g)
      if let r = try ctx.control(["cmd": "clear"]) {
        guard r["ok"] as? Bool == true else { throw UserError(r["error"] as? String ?? "the gateway could not clear activity") }
      } else {
        try await LogCmd.direct(ctx) { try await $0.clear() }
      }
      CLI.out("Activity cleared. Backups made before the folder was excluded may still hold old copies; Homebot can't delete those.")
    }
  }
}

// MARK: account

struct AccountCmd: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "account", abstract: "The Cursor API key Homebot uses.", subcommands: [SetKey.self, Show.self, RemoveKey.self])

  struct SetKey: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set-key", abstract: "Save a Cursor API key read from standard input (never from an argument).")
    @OptionGroup var g: Global

    func run() async throws {
      let ctx = try await Ctx.open(g)
      guard let input = CLI.io.readStdin(), !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw UserError("no key on standard input; pipe it in, e.g. pbpaste | homebot account set-key")
      }
      try ctx.credentials.save(key: input)
      CLI.out("Saved the API key (\(ctx.home.apiKey.path), mode 0600).")
      try await AccountCmd.check(ctx)
    }
  }

  /// A read-only call with the key in use; bots need not exist (then the check waits for the
  /// first question). Never creates a bot.
  static func check(_ ctx: Ctx) async throws {
    guard let b = await ctx.config.bots().first else {
      CLI.out("Grok Bot: unchecked (no bot yet; the key is checked when a bot is added)")
      return
    }
    do {
      _ = try await ctx.client().getEntries(sessionId: b.sessionId, afterUpdatedSeq: (await ctx.state.cursor(b.key))?.cursor ?? "-1")
      CLI.out("Grok Bot: accepted")
    } catch let e as BdkError where e.kind == .auth {
      CLI.out("Grok Bot: rejected the key (\(e.status.map(String.init) ?? "auth"))")
      throw ExitCode(1)
    } catch {
      CLI.out("Grok Bot: not reachable (\(HomebotCLI.describeOwn(error) ?? "error")); the key is checked again on the next question")
    }
  }

  struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Which credential is used (never the key itself), and whether Grok Bot accepts it.")
    @OptionGroup var g: Global

    func run() async throws {
      let ctx = try await Ctx.open(g)
      let c = try ctx.credentials.resolve()
      CLI.out("Credential: \(c?.source.rawValue ?? "none")")
      let login: String
      switch ctx.credentials.loginStatus {
      case .none: login = "none"
      case .usable: login = "found (usable)"
      case .otherBackend: login = "found, for another server (not used)"
      case .unreadable: login = "found, unreadable (not used)"
      }
      CLI.out("Grok Bot login on this Mac: \(login)")
      if c != nil { try await AccountCmd.check(ctx) }
    }
  }

  struct RemoveKey: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove-key", abstract: "Delete the saved key (a usable Grok Bot login is used again).")
    @OptionGroup var g: Global

    func run() async throws {
      let ctx = try await Ctx.open(g)
      try ctx.credentials.removeSaved()
      CLI.out("Removed the saved key. Credential now: \((try ctx.credentials.resolve())?.source.rawValue ?? "none").")
    }
  }
}

// MARK: import

struct Import: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Import the TypeScript version's folder (~/.homebot): bots, cursors, Shortcut tokens, settings and its key. The old folder is then marked as moved.")
  @OptionGroup var g: Global
  @Option(help: "The TypeScript folder (default: ~/.homebot).") var from: String?
  @Option(name: .customLong("keep"), help: "Keep this pre-M4 token (made without a session) for its bot's current conversation. Repeatable.") var keep: [String] = []
  @Flag(name: .customLong("dry-run"), help: "Only show what would be imported.") var dryRun = false

  func run() async throws {
    let io = CLI.io
    let ctx = try await Ctx.open(g)
    let src = from.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) } ?? TSImport.defaultSource(userHome: io.userHome)
    let p = try TSImport.preview(src)
    CLI.out("From \(src.path): \(p.bots.count) bot(s), \(p.tokens.count) Shortcut token(s), key: \(p.hasKey ? "yes" : "no")\(p.moved ? " (already marked as moved)" : "").")
    for b in p.bots { CLI.out("  bot \(b.key)\t\(b.name)\t\(b.sessionId)") }
    for t in p.tokens {
      let note = t.sessionless ? (keep.contains(t.id) ? "kept for \(t.bot) (your choice)" : "made before M4: imported retired unless --keep \(t.id)") : ""
      CLI.out("  token \(t.id)\t\(t.bot)\t\(t.state)\t\(t.label)\(note.isEmpty ? "" : "\t\(note)")")
    }
    if dryRun { return }
    let r = try await TSImport.run(from: src, to: ctx.home, keep: Set(keep), isListening: io.isListening)
    CLI.out("Imported \(r.bots) bot(s), \(r.cursors) cursor(s), \(r.usable) usable and \(r.retired) retired Shortcut token(s)\(r.keyCopied ? ", and the API key" : "").")
    CLI.out("\(src.path) is now marked as moved; the TypeScript version refuses to run on it.")
    if try ctx.credentials.resolve() == nil {
      CLI.out("No API key yet: save one with `homebot account set-key`.")
      return
    }
    try await ctx.config.load()
    try await ctx.state.load()
    try await AccountCmd.check(ctx)
  }
}

// MARK: reset

struct ResetCmd: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "reset", abstract: "Start over: delete all bots, Shortcut tokens, built Shortcut files, activity, logs and settings in the support folder.")
  @OptionGroup var g: Global
  @Flag(name: .customLong("remove-key"), help: "Also delete the saved API key (a Grok Bot login on this Mac is kept).") var removeKey = false
  @Flag(help: "Do it; without this, only say what would be deleted.") var yes = false

  func run() async throws {
    // Not Ctx.open: a reset must work on stores that can't be read, and the preview changes
    // nothing (not even the 24 h cleanup of Shortcut files).
    let io = CLI.io
    let root = g.home.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) } ?? io.defaultHome
    let home = try Home(root: root)
    guard yes else {
      let bots = (try? await ConfigStore(file: home.config).load().bots().count) ?? 0
      let tokens = (try? await TokenStore(file: home.tokens).load().list().count) ?? 0
      CLI.out("This deletes, in \(home.root.path): \(bots) bot(s), \(tokens) Shortcut token(s), the built Shortcut files, activity, logs and settings\(removeKey ? ", and the saved API key" : " (the saved API key stays; add --remove-key to delete it)").")
      CLI.out("Shortcuts already on your iPhone or Mac stop working; delete them in the Shortcuts app.")
      CLI.out("Run again with --yes to reset.")
      throw ExitCode(1)
    }
    let r = try await Reset.run(home, removeKey: removeKey, userHome: io.userHome)
    CLI.out("Reset: removed \(r.bots) bot(s) and \(r.shortcuts) Shortcut token(s), the built Shortcut files, activity, logs and settings\(r.keyRemoved ? ", and the saved API key" : "").")
    CLI.out("Shortcuts already on your iPhone or Mac stop working; delete them in the Shortcuts app.")
    CLI.out("Credential now: \((try Credentials(keyFile: home.apiKey, userHome: io.userHome).resolve())?.source.rawValue ?? "none").")
  }
}

// MARK: lab

struct LabCmd: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "lab", abstract: "Device experiments (DESIGN §19).", subcommands: [Use.self, Report.self])

  struct Use: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Choose the experiment the lab Shortcut runs next.")
    @OptionGroup var g: Global
    @Argument var scenario: String
    @Option(help: "E7 delays in whole seconds, e.g. 8,12,16.") var delays: String?

    func run() async throws {
      let ctx = try await Ctx.open(g)
      guard let id = LabScenario(rawValue: scenario) else { throw UserError("Choose one of: \(LabScenario.allCases.map(\.rawValue).joined(separator: ", "))") }
      let d = try delays.map { s -> [Int] in
        let parts = s.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.allSatisfy({ ($0 ?? 0) >= 1 && ($0 ?? 0) <= 120 }) else { throw UserError("--delays takes whole seconds from 1 to 120, e.g. 8,12,16") }
        return parts.map { $0! }
      }
      try Lab.writeState(ctx.home.lab, scenario: id, delays: d)
      let shown = id == .e7 ? " (delays \((d ?? Lab.readState(ctx.home.lab).delays).map(String.init).joined(separator: ", ")) s, one per run)" : ""
      CLI.out("The lab Shortcut now runs \(id.rawValue)\(shown). A running gateway picks this up on the next run.")
    }
  }

  struct Report: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the lab results since the last `lab use` (no speech text is ever stored).")
    @OptionGroup var g: Global
    @Flag var all = false

    func run() async throws {
      let ctx = try await Ctx.open(g)
      let since = all ? 0 : Lab.readState(ctx.home.lab).version
      let text = (try? String(contentsOf: ctx.home.logs.appendingPathComponent("homebot.jsonl"), encoding: .utf8)) ?? ""
      let cols = ["time", "scenario", "run", "step", "mode", "recv_len", "match", "gap_ms", "delay_ms", "client_gave_up_ms"]
      CLI.out(cols.joined(separator: "\t"))
      let iso = ISO8601DateFormatter()
      iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      var n = 0
      for line in text.split(separator: "\n") {
        guard let e = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], e["event"] as? String == "lab", let ts = e["ts"] as? String,
              let date = iso.date(from: ts) ?? ISO8601DateFormatter().date(from: ts), date.timeIntervalSince1970 * 1000 >= since else { continue }
        n += 1
        CLI.out(cols.map { c in
          if c == "time" { return String(ts.dropFirst(11).prefix(8)) }
          guard let v = e[c] else { return c == "step" ? "" : "-" }
          return "\(v)"
        }.joined(separator: "\t"))
      }
      if n == 0 { CLI.out(all ? "No lab results yet." : "No lab results since the last \"homebot lab use\" (try --all).") }
    }
  }
}
