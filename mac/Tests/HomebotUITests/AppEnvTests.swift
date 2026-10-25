// Launch arguments: a normal launch changes nothing; dev mode never reaches Cursor's API, binds
// loopback on its own port and uses its own folder; dev options without --dev are refused.
import Foundation
import Testing

import HomebotCore
@testable import HomebotUI

@Suite struct AppEnvTests {
  @Test func normalLaunchUsesTheDefaults() throws {
    let e = try AppEnv.parse(["-NSDocumentRevisionsDebugMode", "YES", "-ApplePersistenceIgnoreState", "YES"])
    #expect(!e.dev)
    #expect(e.home == nil)
    #expect(e.port == nil)
    #expect(e.bdkBaseURL == HTTPBdkClient.defaultBaseURL)
    #expect(e.sign == nil)
    #expect(!e.fakeLoginItem)
  }

  @Test func devOptionsNeedDev() {
    for args in [["--bdk-base-url", "http://127.0.0.1:1/v0/grokbot/sessions"], ["--dev-seed", "bot"], ["--dev-page", "home"], ["--dev-lang", "de"], ["--dev-app-icon", "white"], ["--dev-bdk-login"]] {
      #expect(throws: AppEnv.UsageError.self) { try AppEnv.parse(args) }
    }
  }

  @Test func devModeIsIsolated() throws {
    let root = try shortDir()
    let e = try AppEnv.parse(["--dev", "--dev-home", root.path, "--dev-seed", "shortcut", "--dev-lang", "ja", "--dev-appearance", "dark", "--dev-app-icon", "black", "--dev-page", "bot"])
    #expect(e.dev)
    #expect(e.home == root.appendingPathComponent("support", isDirectory: true))
    #expect(e.userHome == root.appendingPathComponent("user", isDirectory: true))
    #expect(e.port == 18787)
    #expect(e.bind == "127.0.0.1")
    #expect(e.bdkBaseURL == AppEnv.deadEnd)
    #expect(e.sign != nil)
    #expect(e.fakeLoginItem)
    #expect(e.seed == .shortcut)
    #expect(e.uiLang == .ja)
    #expect(e.appearance == .dark)
    #expect(e.appIcon == .black)
    #expect(e.page == "bot")
  }

  @Test func devModeRefusesARealAPI() {
    for url in [HTTPBdkClient.defaultBaseURL, "https://example.com/v0/grokbot/sessions", "http://192.168.1.2:80/v0/grokbot/sessions"] {
      #expect(throws: AppEnv.UsageError.self) { try AppEnv.parse(["--dev", "--bdk-base-url", url]) }
    }
    #expect(throws: AppEnv.UsageError.self) { try AppEnv.parse(["--dev", "--dev-seed", "everything"]) }
    #expect(throws: AppEnv.UsageError.self) { try AppEnv.parse(["--dev", "--dev-lang"]) }
    #expect(throws: AppEnv.UsageError.self) { try AppEnv.parse(["--dev", "--dev-app-icon", "rainbow"]) }
  }

  @Test func theDevSignerOnlyCopies() async throws {
    let root = try shortDir()
    let e = try AppEnv.parse(["--dev", "--dev-home", root.path])
    let a = root.appendingPathComponent("in.shortcut"), b = root.appendingPathComponent("out.shortcut")
    try Data("plist".utf8).write(to: a)
    try await e.sign!(a.path, b.path)
    #expect(try Data(contentsOf: b) == Data("plist".utf8))
  }

  @Test func devBdkLoginIsAFakeLoginFile() throws {
    let root = try shortDir()
    let e = try AppEnv.parse(["--dev", "--dev-home", root.path, "--dev-bdk-login"])
    let f = e.userHome.appendingPathComponent(".config/agent-serve/credentials.json")
    let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as? [String: String]
    #expect(obj?["apiKey"] == DevSeed.fakeKey)
  }
}

@Suite struct AppEnvDevGuardTests {
  @Test func devRefusesReservedPorts() {
    for port in [8787, 8788, 18787] {
      #expect(throws: AppEnv.UsageError.self) { try AppEnv.parse(["--dev", "--bdk-base-url", "http://127.0.0.1:\(port)/v0/grokbot/sessions"]) }
    }
  }

  @Test func devHomeMustNotBeARealFolder() throws {
    let user = try shortDir()
    let real = user.appendingPathComponent(".homebot")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let support = user.appendingPathComponent("Library/Application Support/Homebot")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    for bad in [real, real.appendingPathComponent("x"), support, user] {
      #expect(throws: AppEnv.UsageError.self) { try AppEnv.checkDevRoot(bad, userHome: user) }
    }
    // A link named support that leads elsewhere.
    let root = try shortDir()
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("support"), withDestinationURL: real)
    #expect(throws: AppEnv.UsageError.self) { try AppEnv.checkDevRoot(root, userHome: user) }
    try AppEnv.checkDevRoot(try shortDir(), userHome: user)
  }
}
