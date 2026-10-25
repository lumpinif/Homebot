import Foundation
import IOKit.pwr_mgt
import Network
import Security
import ServiceManagement

/// One spike check and what it found. Every result is also appended to results.jsonl so the
/// findings survive the app and can be read without the window.
struct ProbeResult: Codable, Identifiable {
  var id = UUID()
  let probe: String
  let ok: Bool
  let detail: String
  let at: Date
}

@MainActor
final class Probes: ObservableObject {
  @Published var results: [ProbeResult] = []
  private var listener: NWListener?
  private var assertion: IOPMAssertionID = 0
  private var activity: NSObjectProtocol?

  static let port: UInt16 = 18797
  static let keychainService = "win.cloudman.homebot.spike"
  static var supportDir: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HomebotSpike", isDirectory: true)
  }

  func record(_ probe: String, _ ok: Bool, _ detail: String) {
    let r = ProbeResult(probe: probe, ok: ok, detail: detail, at: Date())
    results.insert(r, at: 0)
    let dir = Self.supportDir
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let file = dir.appendingPathComponent("results.jsonl")
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    guard var line = try? enc.encode(r) else { return }
    line.append(0x0A)
    if let h = try? FileHandle(forWritingTo: file) {
      h.seekToEndOfFile()
      h.write(line)
      try? h.close()
    } else {
      FileManager.default.createFile(atPath: file.path, contents: line, attributes: [.posixPermissions: 0o600])
    }
  }

  // MARK: Environment

  func environment() {
    let b = Bundle.main
    let path = b.bundlePath
    record("environment", true, [
      "bundle=\(path)",
      "translocated=\(path.contains("/AppTranslocation/"))",
      "id=\(b.bundleIdentifier ?? "none")",
      "version=\(b.infoDictionary?["CFBundleVersion"] as? String ?? "?")",
      "arch=\(Self.arch)",
      "AGENT_SERVE_CONFIG_DIR set=\(ProcessInfo.processInfo.environment["AGENT_SERVE_CONFIG_DIR"] != nil)",
    ].joined(separator: " "))
  }

  static var arch: String {
    #if arch(arm64)
    return "arm64"
    #else
    return "x86_64"
    #endif
  }

  // MARK: Login item

  func loginItemStatus() {
    record("login-item-status", true, describe(SMAppService.mainApp.status))
  }

  func registerLoginItem() {
    // A translocated copy runs from a random read-only path; a login item would point there.
    if Bundle.main.bundlePath.contains("/AppTranslocation/") {
      return record("login-item-register", false, "refused: running translocated; move Homebot to Applications first")
    }
    do {
      try SMAppService.mainApp.register()
      record("login-item-register", true, "status after: \(describe(SMAppService.mainApp.status))")
    } catch {
      record("login-item-register", false, "\(error) status: \(describe(SMAppService.mainApp.status))")
    }
  }

  func unregisterLoginItem() {
    do {
      try SMAppService.mainApp.unregister()
      record("login-item-unregister", true, "status after: \(describe(SMAppService.mainApp.status))")
    } catch {
      record("login-item-unregister", false, "\(error)")
    }
  }

  private func describe(_ s: SMAppService.Status) -> String {
    switch s {
    case .notRegistered: "notRegistered"
    case .enabled: "enabled"
    case .requiresApproval: "requiresApproval"
    case .notFound: "notFound"
    @unknown default: "unknown(\(s.rawValue))"
    }
  }

  // MARK: Keychain (a dummy value, never a real key)

  func keychainWrite() {
    let value = "spike-value-\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")"
    let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: "spike"]
    SecItemDelete(base as CFDictionary)
    var add = base
    add[kSecValueData as String] = Data(value.utf8)
    let st = SecItemAdd(add as CFDictionary, nil)
    record("keychain-write", st == errSecSuccess, "status \(st) wrote \(value)")
  }

  func keychainRead() {
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: "spike", kSecReturnData as String: true]
    var out: CFTypeRef?
    let st = SecItemCopyMatching(q as CFDictionary, &out)
    let text = (out as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? "-"
    record("keychain-read", st == errSecSuccess, "status \(st) value \(text) (this build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
  }

  // MARK: LAN listener

  func startListener() {
    guard listener == nil else { return record("listener", true, "already listening on \(Self.port)") }
    do {
      let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
      l.newConnectionHandler = { [weak self] conn in
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
          let firstLine = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first.map(String.init) ?? "?"
          let remote = "\(conn.endpoint)"
          let body = "Homebot spike is reachable.\n"
          let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
          conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
          Task { @MainActor in self?.record("listener-request", true, "\(firstLine) from \(remote)") }
        }
      }
      l.stateUpdateHandler = { [weak self] state in
        Task { @MainActor in self?.record("listener-state", { if case .failed = state { return false }; return true }(), "\(state)") }
      }
      l.start(queue: .main)
      listener = l
    } catch {
      record("listener", false, "\(error)")
    }
  }

  // MARK: Sleep assertion

  func holdAwake() {
    guard assertion == 0 else { return record("awake", true, "already held (id \(assertion))") }
    let st = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Homebot spike: serving Siri" as CFString, &assertion)
    activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Homebot spike: serving Siri")
    record("awake", st == kIOReturnSuccess, "IOPMAssertionCreateWithName \(st), id \(assertion), plus a ProcessInfo activity; check with: pmset -g assertions")
  }

  func releaseAwake() {
    guard assertion != 0 else { return }
    IOPMAssertionRelease(assertion)
    assertion = 0
    record("awake-release", true, "released")
  }

  // MARK: shortcuts CLI (help only: never `shortcuts sign`, which calls Apple)

  func shortcutsCLI() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
    p.arguments = ["help", "sign"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do {
      try p.run()
      p.waitUntilExit()
      let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      record("shortcuts-cli", p.terminationStatus == 0, "exit \(p.terminationStatus): \(out.prefix(160).replacingOccurrences(of: "\n", with: " "))")
    } catch {
      record("shortcuts-cli", false, "\(error)")
    }
  }

  func runAll() {
    environment()
    loginItemStatus()
    keychainRead()
    startListener()
    holdAwake()
    shortcutsCLI()
  }
}
